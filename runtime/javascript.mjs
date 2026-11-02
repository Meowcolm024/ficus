// Ficus support runtime. The compiler appends numeric layouts and generated
// functions; no source AST or source-name environment is shipped.
import * as fs from 'node:fs';

const cell = (value) => ({value});
function readCell(c) {
  if (c.value === undefined) throw new Error('recursive value read before initialization');
  return c.value;
}
const push = (e, frame) => ({frames: [frame, ...e.frames], captures: e.captures});
const aggregate = (tag, fields) => ({tag, fields});
const token = (tag, args) => ({token: tag, args});
const transfer = (fn, arg) => ({transfer: true, fn, arg});
function closure(code, arity, captures) {
  return {code, arity, env: {frames: [], captures}, args: []};
}
function apply(fn, arg) {
  for (;;) {
    if (!fn || typeof fn.code !== 'function') throw new Error('application requires a function');
    const args = [...fn.args, arg];
    if (args.length < fn.arity) return {...fn, args};
    const result = fn.code(push(fn.env, args.map(cell)));
    if (!result || result.transfer !== true) return result;
    fn = result.fn;
    arg = result.arg;
  }
}
function select(value, tag, field) {
  if (!value || value.tag !== tag) throw new Error('selection requires the expected aggregate');
  return value.fields[field];
}
function list(values) {
  let result = aggregate(0, []);
  for (let i = values.length - 1; i >= 0; --i) result = aggregate(1, [values[i], result]);
  return result;
}
function elements(value) {
  const result = [];
  while (value && value.tag === 1) {
    result.push(value.fields[0]);
    value = value.fields[1];
  }
  if (!value || value.tag !== 0) throw new Error('list representation expected');
  return result;
}
const wrap = (value) => BigInt.asIntN(64, value);
function lessText(a, b) {
  const left = Array.from(a, c => c.codePointAt(0));
  const right = Array.from(b, c => c.codePointAt(0));
  for (let i = 0; i < Math.min(left.length, right.length); ++i) {
    if (left[i] !== right[i]) return left[i] < right[i];
  }
  return left.length < right.length;
}
// Match the interpreter's shortest-decimal presentation (including -0.0).
function showFloat(value) {
  if (!Number.isFinite(value)) return String(value);
  if (Object.is(value, -0)) return '-0.0';
  const negative = value < 0 ? '-' : '';
  const text = Math.abs(value).toExponential();
  const [mantissa, exponentText] = text.split('e');
  const exponent = Number(exponentText);
  const digits = mantissa.replace('.', '');
  if (exponent < -1 || exponent >= 7) {
    return negative + digits[0] + '.' + (digits.slice(1) || '0') + 'e' + exponent;
  }
  const decimal = exponent + 1;
  if (decimal === 0) return negative + '0.' + digits;
  return negative + (decimal >= digits.length
    ? digits + '0'.repeat(decimal - digits.length) + '.0'
    : digits.slice(0, decimal) + '.' + digits.slice(decimal));
}
class FicusThrown extends Error {
  constructor(identity, payload, evidence, context) {
    super(context + 'uncaught exception');
    this.identity = identity;
    this.payload = payload;
    this.evidence = evidence;
  }
}
function sameToken(a, b) {
  return a.token === b.token && a.args.length === b.args.length && a.args.every((v, i) => sameToken(v, b.args[i]));
}
const exceptionIdentity = dictionary => dictionary.fields[1];
const exceptionRenderer = dictionary => dictionary.fields[0].fields[0];
function throwException(dictionary, value, context, packaged) {
  const identity = exceptionIdentity(dictionary);
  if (packaged && identity.token === packaged.identity && identity.args.length === 0 && value.tag === packaged.tag) {
    const underlying = value.fields[0];
    const display = underlying.fields[0];
    const evidence = aggregate(underlying.tag, [aggregate(display.tag, [value.fields[packaged.renderer]]), underlying.fields[1]]);
    throwException(evidence, value.fields[packaged.value], context, packaged);
  }
  throw new FicusThrown(identity, value, dictionary, context);
}
function primitiveFailure(kind, fields, context, message, errors, globals) {
  const [identity, representation, evidence] = errors[kind];
  const payload = representation === null ? fields[0] : aggregate(representation, fields);
  throw new FicusThrown(token(identity, []), payload, evidence === null ? null : readCell(globals[evidence]), context + message + ': ');
}
function ioFailure(operation, message, context, errors, globals) {
  return primitiveFailure(2, [operation, message], context, operation + ': ' + message, errors, globals);
}
function io(operation, context, errors, globals, action) {
  try { return action(); }
  catch (error) {
    if (error instanceof FicusThrown) throw error;
    return ioFailure(operation, error.message, context, errors, globals);
  }
}
function readCharacter(handle) {
  const bytes = Buffer.alloc(4);
  if (fs.readSync(handle.fd, bytes, 0, 1, null) === 0) return null;
  const first = bytes[0];
  const size = first < 0x80 ? 1 : first >= 0xc2 && first <= 0xdf ? 2 : first <= 0xef && first >= 0xe0 ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
  if (size === 0) throw new Error('invalid UTF-8 input');
  for (let i = 1; i < size; ++i) {
    if (fs.readSync(handle.fd, bytes, i, 1, null) === 0) throw new Error('incomplete UTF-8 input');
  }
  return new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(bytes.subarray(0, size));
}
function primitive(operation, args, context, errors, modes, packaged, globals) {
  const [a, b, c] = args;
  switch (operation) {
    case op.IntAdd: return wrap(a + b);
    case op.IntSubtract: return wrap(a - b);
    case op.IntMultiply: return wrap(a * b);
    case op.IntNegate: return wrap(-a);
    case op.IntDivide:
    case op.IntRemainder:
      if (b === 0n) return primitiveFailure(0, [], context, 'integer division by zero', errors, globals);
      return wrap(operation === op.IntDivide ? a / b : a % b);
    case op.IntEqual: case op.FloatEqual: case op.CharEqual: case op.StringEqual: return a === b;
    case op.IntLess: case op.FloatLess: return a < b;
    case op.IntShow: return String(a);
    case op.IntToFloat: return Number(a);
    case op.FloatAdd: return a + b;
    case op.FloatSubtract: return a - b;
    case op.FloatMultiply: return a * b;
    case op.FloatDivide: return a / b;
    case op.FloatNegate: return -a;
    case op.FloatShow: return showFloat(a);
    case op.FloatToInt: {
      const fail = message => primitiveFailure(1, [message], context, message, errors, globals);
      if (!Number.isFinite(a)) return fail('cannot convert a non-finite float to Int');
      const value = BigInt(Math.trunc(a));
      if (value < -(1n << 63n) || value >= (1n << 63n)) return fail('float is outside the Int range');
      return value;
    }
    case op.CharLess: case op.StringLess: return lessText(a, b);
    case op.CharShow: return a;
    case op.StringAppend: return a + b;
    case op.StringLength: return wrap(BigInt(Array.from(a).length));
    case op.StringToChars: return list(Array.from(a));
    case op.CharsToString: return elements(a).join('');
    case op.VecFromList: return elements(a);
    case op.VecToList: return list(a);
    case op.VecLength: return BigInt(a.length);
    case op.ByteFromInt: return Number(BigInt.asUintN(8, a));
    case op.ByteToInt: return BigInt(a);
    case op.RefNew: return {ref: a};
    case op.RefRead: return a.ref;
    case op.RefModify: { const result = apply(b, a.ref); a.ref = result; return null; }
    case op.MatchFailure: return primitiveFailure(3, [a], context, a, errors, globals);
    case op.Throw: return throwException(a, b, context, packaged);
    case op.Catch: {
      let thrown;
      try { return apply(b, null); }
      catch (error) {
        if (!(error instanceof FicusThrown)) throw error;
        thrown = error;
      }
      const expected = exceptionIdentity(a);
      if (packaged && expected.token === packaged.identity && expected.args.length === 0) {
        if (!thrown.evidence) throw new Error('missing primitive exception rendering evidence');
        const fields = [thrown.evidence, null, null];
        fields[packaged.value] = thrown.payload;
        fields[packaged.renderer] = exceptionRenderer(thrown.evidence);
        return apply(c, aggregate(packaged.tag, fields));
      }
      if (sameToken(expected, thrown.identity)) return apply(c, thrown.payload);
      throw thrown;
    }
    case op.HandleStdin: return {fd: 0, readable: true, writable: false, standard: true, closed: false};
    case op.HandleStdout: return {fd: 1, readable: false, writable: true, standard: true, closed: false};
    case op.HandleStderr: return {fd: 2, readable: false, writable: true, standard: true, closed: false};
    case op.HandleOpenFile: return io('openFile', context, errors, globals, () => {
      const mode = modes[b.tag];
      let fd;
      if (mode === 'r+') {
        try { fd = fs.openSync(a, 'r+'); }
        catch (error) { if (error.code !== 'ENOENT') throw error; fd = fs.openSync(a, 'w+'); }
      } else fd = fs.openSync(a, mode);
      return {fd, readable: mode === 'r' || mode === 'r+', writable: mode !== 'r', standard: false, closed: false};
    });
    case op.HandleClose:
      if (a.standard) return ioFailure('close', 'cannot close a standard handle', context, errors, globals);
      return io('close', context, errors, globals, () => { if (!a.closed) fs.closeSync(a.fd); a.closed = true; return null; });
    case op.HandleRead:
      if (a.standard && !a.readable) return ioFailure('read', 'handle is not readable', context, errors, globals);
      if (b <= 0n) return '';
      return io('read', context, errors, globals, () => {
        if (a.closed || !a.readable) throw new Error('handle is not readable');
        const characters = [];
        for (let n = 0n; n < b; ++n) {
          const character = readCharacter(a);
          if (character === null) break;
          characters.push(character);
        }
        return characters.join('');
      });
    case op.HandleWrite:
      if (a.standard && !a.writable) return ioFailure('write', 'handle is not writable', context, errors, globals);
      return io('write', context, errors, globals, () => {
        if (a.closed || !a.writable) throw new Error('handle is not writable');
        const bytes = Buffer.from(b, 'utf8');
        let offset = 0;
        while (offset < bytes.length) offset += fs.writeSync(a.fd, bytes, offset, bytes.length - offset);
        return null;
      });
    default: throw new Error('unknown runtime primitive');
  }
}
