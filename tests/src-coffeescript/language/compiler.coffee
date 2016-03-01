
dispatchTable =
  func: (engine, vars, body) ->
    locals: []
    tsets: {body}
    body: "(function(engine, $this) { body(v)->{#1 return v; }#1 })"
  collect: (engine, vars, formula) ->
    locals: ["s"]
    tsets: {formula}
    body: "var s = set(); formula(v)->{#1 s.add(v); }#1 yield s;"
  lit: (engine, vars, type, elements) ->
    locals: ["e"]
    tsets: {}
    body: ("e = #{JSON.stringify(e)}; yield e;" for e in elements).join("")
  up: (engine, vars, startCellsTset, targetColId, wantValues) ->
    nLevels = engine.calcLevelsUp(startCellsTset.type, targetColId)
    elementExpr = if wantValues then "v[v.length-#{nLevels+1}]" else "v.slice(0, v.length-#{nLevels})"
    locals: ["s", "e"]
    tsets: {start: startCellsTset}
    body: "var s = set(), e; start(v)->{#1
        e = #{elementExpr}; yield e;
      }#1"
  down: (engine, vars, startCellsTset, targetColId, keysTset, wantValues) ->
    elementExpr = if wantValues then 'x[i]' else 'v.concat([x[i]])'
    if keysTset == null
      locals: ["s", "x", "i", "e"]
      tsets: {start: startCellsTset}
      body: "var s = set(), x, e; start(v)->{#1
        if (!s.has(v)){s.add(v);
          x = engine.readFamily('#{targetColId}', v);
          for (var i=0; i<x.length; i++) { e=#{elementExpr}; yield e; }}
        }#1"
    else
      locals: ["s", "x", "i", "e"]
      tsets: {start: startCellsTset, keys: ["collect", keysTset]}
      body: "var s = set(), x, e; keys(k)->{#1 start(v)->{#2
        if (!s.has(v)){s.add(v);
          x = engine.readFamily('#{targetColId}', v);
          for (var i=0; i<x.length; i++) {
            if (k.has(x[i])) { e=#{elementExpr}; yield e; } } }
        }#2 }#1"
  filter: (engine, vars, universe, where) ->
    locals: []
    tsets: {universe: universe, where: where[1]}
    body: "universe(v)->{#1
        var $#{where[0]} = [v];
        where(u)->{#2 if (u) yield v; }#2
      }#1"
  var: (engine, vars, name) ->
    locals: ['i', 'e']
    tsets: {}
    body: "var e,i; for (i=0; i<$#{name}.length; i++) { e=$#{name}[i]; yield e; }"
  '=': (engine, vars, lhs, rhs) ->
    locals: ['c']
    tsets: {lhs: ["collect", lhs], rhs: ["collect", rhs]}
    body: "lhs(v)->{#1 rhs(u)->{#2 var c=EJSON.equals(v,u); yield c; }#2 }#1"


class @FormulaCompiler

  constructor: (@engine) ->

  compileAsFunc: (formula) ->
    cu = new CompilationUnit(@engine)
    eval(cu.compile(['func', ['collect', formula]]))

  isCompilationSupported: (formula) ->
    d = dispatchTable[formula[0]]
    if d?
      d = d(@engine, {}, formula[1..]...)
      forall (v for k,v of d.tsets), (v) => @isCompilationSupported(v)
    else
      false



class CompilationUnit

  constructor: (@engine) ->
    @mnemonics = {}

  compile: (formula) ->
    d = dispatchTable[formula[0]](@engine, {}, formula[1..]...)
    tsets = {}
    for k,v of d.tsets
      tsets[k] = @compile(v)
    @compileIr(@alpha(d.body, d.locals), tsets)

  compileIr: (ir, tsets) ->
    ir.replace /(\w+)\((\w+)\)->{#(\d+)(.*?)}#\3/g, (m, tset, tset_va, _, body) =>
      around = tsets[tset]
      if !around? then throw Error("IR error: no tset named '#{tset}'")
      s = around.replace /yield\s+(\w+)\s*;?/g, (_, yield_va) ->
        body.replace /\b\w+\b/g, (va) -> if va == tset_va then yield_va else va
      @compileIr(s, tsets)

  alpha: (ir, locals) ->
    mn = {}
    for va in locals
      @mnemonics[va] = idx = (@mnemonics[va] ? -1) + 1
      mn[va] = "#{va}#{idx}"
    ir.replace /\b\w+\b/g, (va) -> mn[va] || va


unittest = ->
  SAMPLE = ["filter",["down",["lit","_root",[[]]],"LKPpqAp57vSyYuLnt",null,false],["m",["=",["down",["down",["var","m"],"2cE9zpTvyL5KbarLW",null,true],"C6eqKtscJPLo34o5A",null,true],["up",["var","this"],"DEGb6RQzFn7AEgLX8",true]]]]

  cu = new CompilationUnit({calcLevelsUp: -> 0})

  code = cu.compile(["func", ["collect", SAMPLE]])

  console.log code

  eval(code)

unless Meteor?
  unittest()
