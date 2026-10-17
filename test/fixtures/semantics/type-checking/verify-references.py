#!/usr/bin/env python3
"""Check authored fixture metadata and isolated GHC/OCaml translations.

Run under `stack exec python3 -- ...` so GHC comes from the Stack toolchain.
This does not execute a Ficus type checker; that stage is not implemented yet.
"""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent


def read_json(path):
    return json.loads(path.read_text())


def check_metadata(cases):
    negative = read_json(ROOT / "expectations.json")
    positive = read_json(ROOT / "positive-expectations.json")
    actual_positive = {f"positive/{p.name}" for p in (ROOT / "positive").glob("*.ficus")}
    assert set(positive) <= actual_positive, "Positive manifest names missing files"
    actual_negative = {f"negative/{p.name}" for p in (ROOT / "negative").glob("*.ficus")}
    assert set(negative) == actual_negative, "Negative inventory differs from manifest"
    expected_new = set(positive) | {p for p in cases if p.startswith("negative/")}
    assert set(cases) == expected_new, "Reference inventory differs from new cases"
    sources = set()
    for path, case in cases.items():
        source = (ROOT / path).read_text()
        assert case["rule"], path
        if path.startswith("positive/"):
            assert positive[path]["types"], path
        else:
            expectation = negative[path]
            for diagnostic in [expectation] + expectation.get("additionalDiagnostics", []):
                line, column, end_line, end_column = diagnostic["span"]
                assert line == end_line, (path, diagnostic)
                actual = source.splitlines()[line - 1][column - 1 : end_column]
                assert actual == diagnostic["source"], (path, actual, diagnostic)
                assert diagnostic["kind"] and diagnostic["code"].startswith("T"), path
        for reference in case["references"]:
            assert reference["result"] in {"accept", "reject"}, reference
            assert reference["compiler"] in {"ghc", "ocaml"}, reference
            assert (ROOT / reference["source"]).is_file(), reference
            assert reference["source"] not in sources, reference
            sources.add(reference["source"])
    actual_sources = {str(p.relative_to(ROOT)) for p in (ROOT / "reference").glob("*.txt")}
    assert sources == actual_sources, "Orphan or missing compiler reference"


def check_reference(item):
    path, reference = item
    compiler = reference["compiler"]
    with tempfile.TemporaryDirectory(prefix="ficus-type-reference-") as directory:
        workspace = Path(directory)
        source = workspace / ("Reference.hs" if compiler == "ghc" else "reference.ml")
        source.write_text((ROOT / reference["source"]).read_text())
        if compiler == "ghc":
            command = [
                "ghc", "-fno-code", "-fforce-recomp", "-v0", "-ddump-types",
                "-fdiagnostics-color=never", "-fno-defer-type-errors",
                "-fno-defer-typed-holes", "-XMonomorphismRestriction",
                "-outputdir", directory, str(source),
            ]
        else:
            command = ["ocamlc", "-c", str(source), "-o", str(workspace / "reference.cmo")]
        result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        actual = "accept" if result.returncode == 0 else "reject"
        # Rejection must be a type error, not a malformed translation or tool failure.
        unrelated = ["parse error", "Syntax error", "not in scope", "Unbound value", "Unbound type"]
        type_error = "error:" in output if compiler == "ghc" else "Error:" in output
        passed = actual == reference["result"] and (
            actual == "accept" or (type_error and not any(word in output for word in unrelated))
        )
        if compiler == "ghc" and actual == "reject":
            actual_codes = Counter(re.findall(r"error: \[(GHC-\d+)\]", output))
            expected_codes = Counter(reference["diagnosticCodes"])
            passed = passed and actual_codes == expected_codes
        return {"fixture": path, "compiler": compiler, "expected": reference["result"],
                "actual": actual, "passed": passed, "output": output}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", choices=["both", "ghc", "ocaml"], default="both")
    parser.add_argument("--report", type=Path, help="Write observed compiler output for review")
    args = parser.parse_args()
    cases = read_json(ROOT / "reference/expectations.json")
    check_metadata(cases)
    compilers = ["ghc", "ocaml"] if args.compiler == "both" else [args.compiler]
    for compiler in compilers:
        executable = "ghc" if compiler == "ghc" else "ocamlc"
        if shutil.which(executable) is None:
            parser.error(f"{executable} is unavailable; no reference checks were skipped")
        flag = "--numeric-version" if compiler == "ghc" else "-version"
        version = subprocess.check_output([executable, flag], text=True).strip()
        print(f"{executable}: {version}")
    jobs = [(path, ref) for path, case in cases.items() for ref in case["references"]
            if ref["compiler"] in compilers]
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(check_reference, jobs))
    for result in results:
        status = "PASS" if result["passed"] else "FAIL"
        print(f"{status} {result['compiler']} {result['fixture']}: {result['actual']}")
        if not result["passed"]:
            print(result["output"])
    if args.report:
        args.report.write_text(json.dumps(results, indent=2) + "\n")
    failed = sum(not r["passed"] for r in results)
    print(f"{len(cases)} fixture contracts checked; {len(results) - failed}/{len(results)} references passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
