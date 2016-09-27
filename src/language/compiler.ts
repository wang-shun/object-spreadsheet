namespace Objsheets {

  let dispatchTable = <fixmeAny>{
    func: (engine: fixmeAny, vars: fixmeAny, body: fixmeAny) => ({
        locals: <fixmeAny>[],
        tsets: {
          body: body
        },
        body: "(function(engine, $this) { body(v)->{#1 return v; }#1 })"
      }),
    collect: (engine: fixmeAny, vars: fixmeAny, formula: fixmeAny) => ({
        locals: ["s"],
        tsets: {
          formula: formula
        },
        body: "var s = set(); formula(v)->{#1 s.add(v); }#1 yield s;"
      }),
    lit: (engine: fixmeAny, vars: fixmeAny, type: fixmeAny, elements: fixmeAny) => ({
        locals: ["e"],
        tsets: {},
        body: (elements.map((e: fixmeAny) => `e = ${JSON.stringify(e)}; yield e;`)).join("")
      }),
    up: (engine: fixmeAny, vars: fixmeAny, startCellsTset: fixmeAny, targetColId: fixmeAny, wantValues: fixmeAny) => {
      let nLevels = engine.calcLevelsUp(startCellsTset.type, targetColId);
      let elementExpr = wantValues ? `v[v.length-${nLevels + 1}]` : `v.slice(0, v.length-${nLevels})`;
      return {
        locals: ["s", "e"],
        tsets: {
          start: startCellsTset
        },
        body: `var s = set(), e; start(v)->{#1        e = ${elementExpr}; yield e;      }#1`  //{elementExpr}; yield e;  //1"
      };
    },
    down: (engine: fixmeAny, vars: fixmeAny, startCellsTset: fixmeAny, targetColId: fixmeAny, keysTset: fixmeAny, wantValues: fixmeAny) => {
      let elementExpr = wantValues ? "x[i]" : "v.concat([x[i]])";
      return keysTset === null ? {
        locals: ["s", "x", "i", "e"],
        tsets: {
          start: startCellsTset
        },
        body: `var s = set(), x, e; start(v)->{#1        if (!s.has(v)){s.add(v);          x = engine.readFamily('${targetColId}', v);          for (var i=0; i<x.length; i++) { e=${elementExpr}; yield e; }}        }#1`  //{targetColId}', v);  //{elementExpr}; yield e; }}  //1"
      } : {
        locals: ["s", "x", "i", "e"],
        tsets: {
          start: startCellsTset,
          keys: ["collect", keysTset]
        },
        body: `var s = set(), x, e; keys(k)->{#1 start(v)->{#2        if (!s.has(v)){s.add(v);          x = engine.readFamily('${targetColId}', v);          for (var i=0; i<x.length; i++) {            if (k.has(x[i])) { e=${elementExpr}; yield e; } } }        }#2 }#1`  //{targetColId}', v);  //{elementExpr}; yield e; } } }  //2 }#1"
      };
    },
    filter: (engine: fixmeAny, vars: fixmeAny, universe: fixmeAny, where: fixmeAny) => ({
        locals: <fixmeAny>[],
        tsets: {
          universe: universe,
          where: where[1]
        },
        body: `universe(v)->{#1        var $${where[0]} = [v];        where(u)->{#2 if (u) yield v; }#2      }#1`  //{where[0]} = [v];  //2 if (u) yield v; }#2  //1"
      }),
    "var": (engine: fixmeAny, vars: fixmeAny, name: fixmeAny) => ({
        locals: ["i", "e"],
        tsets: {},
        body: `var e,i; for (i=0; i<$${name}.length; i++) { e=$${name}[i]; yield e; }`
      }),
    "=": (engine: fixmeAny, vars: fixmeAny, lhs: fixmeAny, rhs: fixmeAny) => ({
        locals: ["c"],
        tsets: {
          lhs: ["collect", lhs],
          rhs: ["collect", rhs]
        },
        body: "lhs(v)->{#1 rhs(u)->{#2 var c=EJSON.equals(v,u); yield c; }#2 }#1"
      })
  };

  export class FormulaCompiler {
    constructor(public engine: fixmeAny) {}

    public compileAsFunc(formula: fixmeAny) {
      let cu = new CompilationUnit(this.engine);
      return eval(cu.compile(["func", ["collect", formula]]));
    }

    public isCompilationSupported(formula: fixmeAny): boolean {
      let d = dispatchTable[formula[0]];
      if (d != null) {
        d = d.apply(null, [this.engine, {}].concat(formula.slice(1)));
        return forall((() => {
          let _results: fixmeAny;
          _results = [];
          for (let k in d.tsets) {
            let v = d.tsets[k];
            _results.push(v);
          }
          return _results;
        })(), (v) => this.isCompilationSupported(v));
      } else {
        return false;
      }
    }
  }

  class CompilationUnit {
    public mnemonics: fixmeAny;

    constructor(public engine: fixmeAny) {
      this.mnemonics = {};
    }

    public compile(formula: fixmeAny) {
      let d = dispatchTable[formula[0]].apply(dispatchTable, [this.engine, {}].concat(formula.slice(1)));
      let tsets = <fixmeAny>{};
      for (let k in d.tsets) {
        let v = d.tsets[k];
        tsets[k] = this.compile(v);
      }
      return this.compileIr(this.alpha(d.body, d.locals), tsets);
    }

    public compileIr(ir: fixmeAny, tsets: fixmeAny) {
      return ir.replace(/(\w+)\((\w+)\)->{#(\d+)(.*?)}#\3/g, (m: fixmeAny, tset: fixmeAny, tset_va: fixmeAny, _: fixmeAny, body: fixmeAny) => {  //(\d+)(.*?)}#\3/g, (m, tset, tset_va, _, body) =>
        let around = tsets[tset];
        if (around == null) {
          throw Error(`IR error: no tset named '${tset}'`);
        }
        let s = around.replace(/yield\s+(\w+)\s*;?/g, (_2: fixmeAny, yield_va: fixmeAny) => body.replace(/\b\w+\b/g, (va: fixmeAny) => va === tset_va ? yield_va : va));
        return this.compileIr(s, tsets);
      });
    }

    public alpha(ir: fixmeAny, locals: fixmeAny) {
      let idx: fixmeAny;
      let mn = <fixmeAny>{};
      for (let va of locals) {
        this.mnemonics[va] = idx = (fallback(this.mnemonics[va], -1)) + 1;
        mn[va] = `${va}${idx}`;
      }
      return ir.replace(/\b\w+\b/g, (va: fixmeAny) => mn[va] || va);
    }
  }

  function unittest() {
    let SAMPLE: fixmeAny = ["filter", ["down", ["lit", "_root", [[]]], "LKPpqAp57vSyYuLnt", null, false], ["m", ["=", ["down", ["down", ["var", "m"], "2cE9zpTvyL5KbarLW", null, true], "C6eqKtscJPLo34o5A", null, true], ["up", ["var", "this"], "DEGb6RQzFn7AEgLX8", true]]]];

    let cu = new CompilationUnit({
      calcLevelsUp: () => 0
    });

    let code = cu.compile(["func", ["collect", SAMPLE]]);

    console.log(code);

    return eval(code);
  }

  if (typeof Meteor === "undefined" || Meteor === null) {
    unittest();
  }

}
