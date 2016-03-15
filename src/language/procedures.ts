// Argument adapters.
//
// Note:
// "validate: (mutableVars, mutableCurrentScopeVars) -> ..."
// - mutableVars is an EJSONKeyedSet<string> of all variables in scope
// - mutableCurrentScopeVars is an EJSONKeyedSet<string> of all variables defined
//   in the current scope, which are the variables that statements are allowed to
//   assign to.
// The "mutable" in the names refers to the fact that both sets are mutated as
// assignments are processed.

namespace Objsheets {

  let VarName = {
    validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, arg: fixmeAny) => {
      valAssert(_.isString(arg), "Variable name must be a string");
    },
    stringify: (model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) => ({
        name: arg,
        str: FormulaInternals.stringifyIdent(arg)
      })
  };
  // This one is mostly for documentation purposes.  Validate, typecheck, and
  // execute for statements all have side effects; if we performed those side
  // effects during the arg adapter phase, we'd be behaving as if the statements
  // ran unconditionally before the control structure, and a control structure for
  // which that behavior is correct would be a pretty boring control structure.
  // Even for stringify, foreach needs to bind a variable first.
  //
  // We could have the arg adapters return partial applications of the
  // validateStatements, etc. functions, but I don't think this helps
  // understandability.
  let Statements = {};
  let OptionalVarName = {
    validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, arg: fixmeAny) => {
      if (arg != null) {
        VarName.validate(mutableVars, mutableCurrentScopeVars, arg);
      }
    },
    stringify: (model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) => arg != null ? VarName.stringify(model, mutableVars, arg) : null
  };
  let procedures_EagerSubformula = {
    // Wrapper needed to strip mutableCurrentScopeVars argument.
    validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, arg: fixmeAny) => {
      FormulaInternals.EagerSubformula.validate(mutableVars, arg);
    },
    // Eta-expanded to avoid a load order dependence.
    typecheck: (model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) => FormulaInternals.EagerSubformula.typecheck(model, mutableVars, arg),
    execute: (model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) => FormulaInternals.EagerSubformula.evaluate(model, mutableVars, arg),
    stringify: (model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) => {
      // Anything that binds a local variable needs the original formula in order
      // to get its type.  Follow the design of stringifySubformula.
      //
      // All contexts in which formulas appear in statements are safe for PRECEDENCE_LOWEST.
      return {
        formula: arg,
        str: FormulaInternals.EagerSubformula.stringify(model, mutableVars, arg).strFor(FormulaInternals.PRECEDENCE_LOWEST)
      };
    }
  };

  // We really just want to think of this as parameterized by two booleans, but I
  // guess a class is the way to do it.
  class EagerFamilyRef {
    constructor(public wantObject: fixmeAny, public wantKeys: fixmeAny) {}

    public validate(mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, fmla: fixmeAny) {
      procedures_EagerSubformula.validate(mutableVars, mutableCurrentScopeVars, fmla);
      valAssert(fmla[0] === "down", "Family reference must be a down navigation.");
      // A single down navigation in concrete syntax will always have
      // wantValues = !isObject, but the simplification code in resolveNavigation
      // generates down navigations to object columns with wantValues = true, and
      // more generally either mismatch can arise from adding/removing object
      // types.
      valAssert(getColumn(fmla[2]).isObject === this.wantObject && fmla[4] === !this.wantObject, this.wantObject ? "new/make only work on object families." : "set/add/remove only work on leaf families.");
      valAssert((fmla[3] != null) === this.wantKeys, this.wantKeys ? "make requires a subscript expression." : "A subscript expression is not allowed.");
    }

    public typecheck(model: fixmeAny, mutableVars: fixmeAny, fmla: fixmeAny) {
      let type = procedures_EagerSubformula.typecheck(model, mutableVars, fmla);
      // EagerFamilyRef is used only as the target of mutations, so we can go ahead
      // and check this here.
      valAssert(getColumn(fmla[2]).formula == null, "Cannot mutate a formula column.");
      return type;
    }

    public execute(model: fixmeAny, mutableVars: fixmeAny, fmla: fixmeAny) {
      return {
        parentCellsTset: evaluateFormula(model, mutableVars, fmla[1]),
        columnId: fmla[2],
        keysTset: fmla[3] != null ? evaluateFormula(model, mutableVars, fmla[3]) : null
      };
    }

    public stringify = procedures_EagerSubformula.stringify;
  }

  function validateAssignment(mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, lhsName: fixmeAny) {
    if (!mutableCurrentScopeVars.has(lhsName)) {
      valAssert(!mutableVars.has(lhsName), `Assignment to ${lhsName} shadows a variable defined ` + "outside the current scope (foreach block).");
      mutableCurrentScopeVars.add(lhsName);
      mutableVars.add(lhsName);
    }
  }

  function indent(str: fixmeAny) {
    return str.replace(/^(?=.)/mg, "  ");
  }

  let procedures_dispatch = <fixmeAny>{
    "let": {
      argAdapters: [VarName, procedures_EagerSubformula],
      validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, lhsName: fixmeAny, rhsFmla: fixmeAny) => {
        validateAssignment(mutableVars, mutableCurrentScopeVars, lhsName);
      },
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, lhsName: fixmeAny, rhsType: fixmeAny) => {
        mutableVars.set(lhsName, rhsType);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, lhsName: fixmeAny, rhsTset: fixmeAny) => {
        mutableVars.set(lhsName, rhsTset);
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, lhsSinfo: fixmeAny, rhsSinfo: fixmeAny) => {
        mutableVars.set(lhsSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, rhsSinfo.formula));
        return `let ${lhsSinfo.str} = ${rhsSinfo.str}\n`;
      }
    },
    set: {
      argAdapters: [new EagerFamilyRef(false, false), procedures_EagerSubformula],
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, lhsType: fixmeAny, rhsType: fixmeAny) => {
        valExpectType("Right operand of ':='", rhsType, lhsType);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, lhsFref: fixmeAny, rhsTset: fixmeAny) => {
        model.invalidateDataCache();
        for (let parentCellId of lhsFref.parentCellsTset.elements()) {
          Cells.upsert({
            column: lhsFref.columnId,
            key: parentCellId
          }, {
            $set: {
              values: rhsTset.elements()
            }
          });
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, lhsSinfo: fixmeAny, rhsSinfo: fixmeAny) => `${lhsSinfo.str} := ${rhsSinfo.str}\n`
    },
    add: {
      argAdapters: [new EagerFamilyRef(false, false), procedures_EagerSubformula],
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, lhsType: fixmeAny, rhsType: fixmeAny) => {
        valExpectType("Right operand of 'add'", rhsType, lhsType);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, lhsFref: fixmeAny, rhsTset: fixmeAny) => {
        model.invalidateDataCache();
        for (let parentCellId of lhsFref.parentCellsTset.elements()) {
          Cells.upsert({
            column: lhsFref.columnId,
            key: parentCellId
          }, {
            $addToSet: {
              values: {
                $each: rhsTset.elements()
              }
            }
          });
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, lhsSinfo: fixmeAny, rhsSinfo: fixmeAny) => `to set ${lhsSinfo.str} add ${rhsSinfo.str}\n`
    },
    remove: {
      argAdapters: [new EagerFamilyRef(false, false), procedures_EagerSubformula],
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, lhsType: fixmeAny, rhsType: fixmeAny) => {
        valExpectType("Right operand of 'remove'", rhsType, lhsType);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, lhsFref: fixmeAny, rhsTset: fixmeAny) => {
        model.invalidateDataCache();
        for (let parentCellId of lhsFref.parentCellsTset.elements()) {
          Cells.update({
            column: lhsFref.columnId,
            key: parentCellId
          }, {
            $pullAll: {
              values: rhsTset.elements()
            }
          });
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, lhsSinfo: fixmeAny, rhsSinfo: fixmeAny) => `from set ${lhsSinfo.str} remove ${rhsSinfo.str}\n`
    },
    "if": {
      argAdapters: [procedures_EagerSubformula, Statements, Statements],
      validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, conditionFmla: fixmeAny, thenBody: fixmeAny, elseBody: fixmeAny) => {
        // We can't simply validate the "then" part and then the "else" part,
        // because a loop in the "else" part shouldn't be reported as shadowing a
        // variable defined only in the "then" part.  Check each part separately;
        // then, all variables that were in the current scope after either part
        // should be in the current scope after the "if".
        let currentScopeVarsByBranch = [thenBody, elseBody].map((branch) => {
          let branchVars = mutableVars.shallowClone();
          let branchCurrentScopeVars = mutableCurrentScopeVars.shallowClone();
          validateStatements(branchVars, branchCurrentScopeVars, branch);
          return branchCurrentScopeVars;
        });
        for (let csv of currentScopeVarsByBranch) {
          for (let varName of csv.elements()) {
            mutableCurrentScopeVars.add(varName);
            mutableVars.add(varName);
          }
        }
      },
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, conditionType: fixmeAny, thenBody: fixmeAny, elseBody: fixmeAny) => {
        valExpectType("if condition", conditionType, "bool");
        let varsByBranch = [thenBody, elseBody].map((branch) => {
          let branchVars = mutableVars.shallowClone();
          typecheckStatements(model, branchVars, branch);
          return branchVars;
        });
        let mergedVars = mergeTypeMaps(varsByBranch[0], varsByBranch[1]);
        // Mutate mutableVars to match mergedVars.  (Maybe if we introduce a real
        // class to track the defined variables, this will be less hacky.)  Here,
        // mergedVars should contain a superset of the keys of mutableVars.
        for (let [k, v] of mergedVars.entries()) {
          mutableVars.set(k, v);
        }
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, conditionTset: fixmeAny, thenBody: fixmeAny, elseBody: fixmeAny) => {
        executeStatements(model, mutableVars, singleElement(conditionTset.set) ? thenBody : elseBody);
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, conditionSinfo: fixmeAny, thenBody: fixmeAny, elseBody: fixmeAny) => {
        let varsAndStringByBranch = [thenBody, elseBody].map((branch) => {
          let branchVars = mutableVars.shallowClone();
          let str = stringifyStatements(model, branchVars, branch);
          return {
            branchVars: branchVars,
            str: str
          };
        });
        let mergedVars = mergeTypeMaps(varsAndStringByBranch[0].branchVars, varsAndStringByBranch[1].branchVars);
        for (let [k, v] of mergedVars.entries()) {
          mutableVars.set(k, v);
        }
        return `if (${conditionSinfo.str}) {\n` + indent(varsAndStringByBranch[0].str) + "}" + (elseBody.length ? " else {\n" + indent(varsAndStringByBranch[1].str) + "}\n" : "\n");
      }
    },
    foreach: {
      argAdapters: [VarName, procedures_EagerSubformula, Statements],
      validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, bindVarName: fixmeAny, domainFmla: fixmeAny, body: fixmeAny) => {
        mutableVars = mutableVars.shallowClone();
        mutableCurrentScopeVars = new EJSONKeyedSet();
        valAssert(!mutableVars.has(bindVarName), `foreach binding of ${bindVarName} shadows a variable defined ` + "outside the current scope (foreach block).");
        mutableCurrentScopeVars.add(bindVarName);
        mutableVars.add(bindVarName);
        validateStatements(mutableVars, mutableCurrentScopeVars, body);
      },
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, domainType: fixmeAny, body: fixmeAny) => {
        mutableVars = mutableVars.shallowClone();
        mutableVars.add(bindVarName);  // TODO TEST THIS
        //mutableVars.set(bindVarName, domainType)
        typecheckStatements(model, mutableVars, body);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, domainTset: fixmeAny, body: fixmeAny) => {
        for (let element of domainTset.elements()) {
          let newVars = mutableVars.shallowClone();
          newVars.set(bindVarName, new TypedSet(domainTset.type, set([element])));
          executeStatements(model, newVars, body);
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, bindVarSinfo: fixmeAny, domainSinfo: fixmeAny, body: fixmeAny) => {
        mutableVars = mutableVars.shallowClone();
        mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, domainSinfo.formula));
        return `foreach (${bindVarSinfo.str} : ${domainSinfo.str}) {\n` + indent(stringifyStatements(model, mutableVars, body)) + "}\n";
      }
    },
    "delete": {
      argAdapters: [procedures_EagerSubformula],
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, objectsType: fixmeAny) => {
        // XXX Duplicating functionality of EagerSubformulaCells in formulas.coffee.
        // It's not worth providing a whole EagerSubformulaCells wrapper yet.
        valAssert(typeIsReference(objectsType), `Expected a set of cells, got set of '${objectsType}'`);
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, objectsTset: fixmeAny) => {
        // XXX: We are relying on objectsTset.type being correct!  This
        // functionality is poorly tested since we introduced typechecking.
        model.invalidateDataCache();
        for (let objectId of objectsTset.elements()) {
          model.recursiveDeleteStateCellNoInvalidate(objectsTset.type, objectId);
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, objectsSinfo: fixmeAny) => `delete ${objectsSinfo.str}\n`
    },
    "new": {
      argAdapters: [OptionalVarName, new EagerFamilyRef(true, false)],
      validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, bindVarName: fixmeAny, fref: fixmeAny) => {
        if (bindVarName != null) {
          validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName);
        }
      },
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, familyType: fixmeAny) => {
        if (bindVarName != null) {
          mutableVars.set(bindVarName, familyType);
        }
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, fref: fixmeAny) => {
        model.invalidateDataCache();
        let objects: fixmeAny = [];
        for (let parentCellId of fref.parentCellsTset.elements()) {
          let token = Random.id();
          Cells.upsert({
            column: fref.columnId,
            key: parentCellId
          }, {
            $addToSet: {
              values: token
            }
          });
          objects.push(cellIdChild(parentCellId, token));
        }
        if (bindVarName != null) {
          mutableVars.set(bindVarName, new TypedSet(fref.columnId, <fixmeAny>set(objects)));
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, bindVarSinfo: fixmeAny, frefSinfo: fixmeAny) => {
        if (bindVarSinfo != null) {
          mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula));
        }
        return (bindVarSinfo != null ? `let ${bindVarSinfo.str} = ` : "") + `new ${frefSinfo.str}\n`;
      }
    },
    make: {
      argAdapters: [OptionalVarName, new EagerFamilyRef(true, true)],
      validate: (mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, bindVarName: fixmeAny, fref: fixmeAny) => {
        if (bindVarName != null) {
          validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName);
        }
      },
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, familyType: fixmeAny) => {
        if (bindVarName != null) {
          mutableVars.set(bindVarName, familyType);
        }
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, bindVarName: fixmeAny, fref: fixmeAny) => {
        model.invalidateDataCache();
        let objects: fixmeAny = [];
        for (let parentCellId of fref.parentCellsTset.elements()) {
          for (let key of fref.keysTset.elements()) {
            // No-op if already exists
            Cells.upsert({
              column: fref.columnId,
              key: parentCellId
            }, {
              $addToSet: {
                values: key
              }
            });
            objects.push(cellIdChild(parentCellId, key));
          }
        }
        if (bindVarName != null) {
          mutableVars.set(bindVarName, new TypedSet(fref.columnId, <fixmeAny>set(objects)));
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, bindVarSinfo: fixmeAny, frefSinfo: fixmeAny) => {
        if (bindVarSinfo != null) {
          mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula));
        }
        return (bindVarSinfo != null ? `let ${bindVarSinfo.str} = ` : "") + `make ${frefSinfo.str}\n`;
      }
    },
    check: {
      argAdapters: [procedures_EagerSubformula],
      typecheck: (model: fixmeAny, mutableVars: fixmeAny, conditionType: fixmeAny) => {
        valExpectType("check condition", conditionType, "bool");
      },
      execute: (model: fixmeAny, mutableVars: fixmeAny, conditionTset: fixmeAny) => {
        if (!singleElement(conditionTset.set)) {
          throw new EvaluationError("check condition failed");
        }
      },
      stringify: (model: fixmeAny, mutableVars: fixmeAny, conditionSinfo: fixmeAny) => `check ${conditionSinfo.str}\n`
    }
  };

  function mergeTypeMaps(vars1: fixmeAny, vars2: fixmeAny) {
    let mergedVars = new EJSONKeyedMap();
    for (let [varName, type1] of vars1.entries()) {
      let type2 = vars2.get(varName);
      mergedVars.set(varName, commonSupertype(type1, fallback(type2, TYPE_ERROR)));
    }
    for (let varName of vars2.keys()) {
      if (vars1.get(varName) == null) {
        mergedVars.set(varName, TYPE_ERROR);
      }
    }
    return mergedVars;
  }

  function paramsToTypeMap(params: fixmeAny) {
    return new EJSONKeyedMap(params.map((p: fixmeAny) => [p.name, p.type]));
  }

  // params must already be in final format.
  export function parseProcedure(stringProc: fixmeAny) {
    let bodyString = stringProc.body;
    if (!/(^|\n)$/.test(bodyString)) {
      bodyString += "\n";
    }

    let parser = setupParserCommon("ENTRY_PROCEDURE", paramsToTypeMap(stringProc.params));
    // The following duplicates the authoritative scoping rules expressed in the
    // statement handlers, but is needed to know the correct types during parsing
    // so we can interpret navigations correctly.
    parser.yy.varsStack = [];
    parser.yy.varsPreviousBranch = null;
    parser.yy.pushVars = function() {
      this.varsStack.push([this.varsPreviousBranch, this.vars]);
      this.varsPreviousBranch = null;
      this.vars = this.vars.shallowClone();
    };
    parser.yy.rollbackVars = function() {
      [this.varsPreviousBranch, this.vars] = this.varsStack.pop();
    };
    parser.yy.nextBranch = function() {
      // assert !this.varsPreviousBranch?
      this.varsPreviousBranch = this.vars;
      this.vars = this.varsStack[this.varsStack.length - 1][1].shallowClone();
    };
    parser.yy.commitVars = function() {
      let newVars = mergeTypeMaps(this.varsPreviousBranch, this.vars);
      this.varsPreviousBranch = this.varsStack.pop()[0];
      this.vars = newVars;
    };

    try {
      return {
        name: stringProc.name,
        params: EJSON.clone(stringProc.params),
        body: parser.parse(bodyString)
      };
    } catch (e) {
      if (e instanceof SyntaxError) {
        throw new FormulaValidationError(e.message);
      } else {
        throw e;
      }
    }
  }

  // Based on validateSubformula
  // mutableVars: EJSONKeyedSet<string>
  //
  // Does not use dispatchStatement for the same reasons as validateSubformula.
  function validateStatement(mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, statement: fixmeAny) {
    var opName: fixmeAny;
    valAssert(_.isArray(statement), "Statement must be an array.");
    valAssert(_.isString(opName = statement[0]), "Statement must begin with an operation name (a string).");
    valAssert(procedures_dispatch.hasOwnProperty(opName), `Unknown operation '${opName}'`);
    let d = procedures_dispatch[opName];
    let args = statement.slice(1);
    valAssert(args.length === d.argAdapters.length, `Wrong number of arguments to '${opName}' (required ${d.argAdapters.length}, got ${args.length})`);
    d.argAdapters.forEach((adapter: fixmeAny, i: fixmeAny) => {
      if (adapter.validate != null) {
        adapter.validate(mutableVars, mutableCurrentScopeVars, args[i]);
      }
    });
    if (d.validate != null) {
      d.validate.apply(d, [mutableVars, mutableCurrentScopeVars].concat(args));
    }
  }

  // Copied from formulas.coffee.  More generality than we need right now.
  function dispatchStatement(action: fixmeAny, statement: fixmeAny, ...contextArgs: fixmeAny[]) {
    let d = procedures_dispatch[statement[0]];
    let args = statement.slice(1);
    let adaptedArgs = d.argAdapters.map((adapter: fixmeAny, i: fixmeAny) => adapter[action] != null ? adapter[action].apply(adapter, contextArgs.concat([args[i]])) : args[i]);
    d[action].apply(d, contextArgs.concat(adaptedArgs));
  }

  function validateStatements(mutableVars: fixmeAny, mutableCurrentScopeVars: fixmeAny, arg: fixmeAny) {
    valAssert(_.isArray(arg), "Expected a list of statements");
    for (let statement of arg) {
      validateStatement(mutableVars, mutableCurrentScopeVars, statement);
    }
  }

  function typecheckStatements(model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) {
    for (let statement of arg) {
      dispatchStatement("typecheck", statement, model, mutableVars);
    }
  }

  function executeStatements(model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) {
    for (let statement of arg) {
      dispatchStatement("execute", statement, model, mutableVars);
    }
  }

  function stringifyStatements(model: fixmeAny, mutableVars: fixmeAny, arg: fixmeAny) {
    return (arg.map((statement: fixmeAny) => dispatchStatement("stringify", statement, model, mutableVars))).join("");
  }

  export function validateProcedure(proc: fixmeAny) {
    check(proc, {
      _id: Match.Optional(String),
      name: String,
      params: [
        {
          name: String,
          type: String,
          singular: Boolean
        }
      ],
      body: Match.Any  // body is fully validated by validateStatements
    });
    try {
      let mutableCurrentScopeVars = new EJSONKeyedSet();
      for (let param of proc.params) {
        valAssert(!mutableCurrentScopeVars.has(param.name), `Duplicate parameter name ${param.name}`);
        mutableCurrentScopeVars.add(param.name);
      }
      let mutableVars = mutableCurrentScopeVars.shallowClone();
      validateStatements(mutableVars, mutableCurrentScopeVars, proc.body);
    } catch (e) {
      // XXX: Want to do this here?
      if (e instanceof FormulaValidationError) {
        throw new Meteor.Error("invalid-procedure", "Invalid procedure: " + e.message);
      } else {
        throw e;
      }
    }
  }

  // Returns nothing.  (If in the future we have procedures that return values,
  // typecheckProcedure would return the procedure's return type.)
  export function typecheckProcedure(model: fixmeAny, proc: fixmeAny) {
    let mutableVars = new EJSONKeyedMap();
    for (let param of proc.params) {
      // XXX Duplicates logic from {Type,ColumnId}.typecheck
      if (typeIsReference(param.type)) {
        valAssert(model.getColumn(param.type) != null, `No column exists with ID ${param.type}`);
      }
      mutableVars.set(param.name, param.type);
    }
    typecheckStatements(model, mutableVars, proc.body);
  }

  // It is assumed that the procedure already passed typecheckProcedure against the
  // current schema.
  //
  // May throw EvaluationError and leave the sheet in an intermediate state.
  export function executeProcedure(model: fixmeAny, proc: fixmeAny, args: fixmeAny) {
    // TODO Validate correct set of arguments present with correct types?
    // Currently we consider that the caller's responsibility.
    for (let param of proc.params) {
      if (param.singular) {
        singleElement(args.get(param.name).set);  // Better error message?
      }
    }
    executeStatements(model, args.shallowClone(), proc.body);
  }

  export function stringifyProcedure(proc: fixmeAny) {
    // C.f. stringifyFormula
    return {
      name: proc.name,
      params: EJSON.clone(proc.params),
      body: stringifyStatements(liteModel, paramsToTypeMap(proc.params), proc.body)
    };
  }

}
