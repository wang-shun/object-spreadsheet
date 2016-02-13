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

let VarName = {
  validate: (mutableVars, mutableCurrentScopeVars, arg) => {
    valAssert(_.isString(arg), "Variable name must be a string");
  },
  stringify: (model, mutableVars, arg) => ({
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
  validate: (mutableVars, mutableCurrentScopeVars, arg) => {
    if (arg != null) {
      VarName.validate(mutableVars, mutableCurrentScopeVars, arg);
    }
  },
  stringify: (model, mutableVars, arg) => arg != null ? VarName.stringify(model, mutableVars, arg) : null
};
let EagerSubformula = {
  // Wrapper needed to strip mutableCurrentScopeVars argument.
  validate: (mutableVars, mutableCurrentScopeVars, arg) => {
    FormulaInternals.EagerSubformula.validate(mutableVars, arg);
  },
  // Eta-expanded to avoid a load order dependence.
  typecheck: (model, mutableVars, arg) => FormulaInternals.EagerSubformula.typecheck(model, mutableVars, arg),
  execute: (model, mutableVars, arg) => FormulaInternals.EagerSubformula.evaluate(model, mutableVars, arg),
  stringify: (model, mutableVars, arg) => {
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
  constructor(public wantObject, public wantKeys) {}

  public validate(mutableVars, mutableCurrentScopeVars, fmla) {
    EagerSubformula.validate(mutableVars, mutableCurrentScopeVars, fmla);
    valAssert(fmla[0] === "down", "Family reference must be a down navigation.");
    // A single down navigation in concrete syntax will always have
    // wantValues = !isObject, but the simplification code in resolveNavigation
    // generates down navigations to object columns with wantValues = true, and
    // more generally either mismatch can arise from adding/removing object
    // types.
    valAssert(getColumn(fmla[2]).isObject === this.wantObject && fmla[4] === !this.wantObject, this.wantObject ? "new/make only work on object families." : "set/add/remove only work on leaf families.");
    valAssert((fmla[3] != null) === this.wantKeys, this.wantKeys ? "make requires a subscript expression." : "A subscript expression is not allowed.");
  }

  public typecheck(model, mutableVars, fmla) {
    let type = EagerSubformula.typecheck(model, mutableVars, fmla);
    // EagerFamilyRef is used only as the target of mutations, so we can go ahead
    // and check this here.
    valAssert(getColumn(fmla[2]).formula == null, "Cannot mutate a formula column.");
    return type;
  }

  public execute(model, mutableVars, fmla) {
    return {
      parentCellsTset: evaluateFormula(model, mutableVars, fmla[1]),
      columnId: fmla[2],
      keysTset: fmla[3] != null ? evaluateFormula(model, mutableVars, fmla[3]) : null
    };
  }

  public stringify = EagerSubformula.stringify;
}

function validateAssignment(mutableVars, mutableCurrentScopeVars, lhsName) {
  if (!mutableCurrentScopeVars.has(lhsName)) {
    valAssert(!mutableVars.has(lhsName), `Assignment to ${lhsName} shadows a variable defined ` + "outside the current scope (foreach block).");
    mutableCurrentScopeVars.add(lhsName);
    mutableVars.add(lhsName);
  }
}

function indent(str) {
  return str.replace(/^(?=.)/mg, "  ");
}

let dispatch = {
  "let": {
    argAdapters: [VarName, EagerSubformula],
    validate: (mutableVars, mutableCurrentScopeVars, lhsName, rhsFmla) => {
      validateAssignment(mutableVars, mutableCurrentScopeVars, lhsName);
    },
    typecheck: (model, mutableVars, lhsName, rhsType) => {
      mutableVars.set(lhsName, rhsType);
    },
    execute: (model, mutableVars, lhsName, rhsTset) => {
      mutableVars.set(lhsName, rhsTset);
    },
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) => {
      mutableVars.set(lhsSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, rhsSinfo.formula));
      return `let ${lhsSinfo.str} = ${rhsSinfo.str}\n`;
    }
  },
  set: {
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula],
    typecheck: (model, mutableVars, lhsType, rhsType) => {
      valExpectType("Right operand of ':='", rhsType, lhsType);
    },
    execute: (model, mutableVars, lhsFref, rhsTset) => {
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
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) => `${lhsSinfo.str} := ${rhsSinfo.str}\n`
  },
  add: {
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula],
    typecheck: (model, mutableVars, lhsType, rhsType) => {
      valExpectType("Right operand of 'add'", rhsType, lhsType);
    },
    execute: (model, mutableVars, lhsFref, rhsTset) => {
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
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) => `to set ${lhsSinfo.str} add ${rhsSinfo.str}\n`
  },
  remove: {
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula],
    typecheck: (model, mutableVars, lhsType, rhsType) => {
      valExpectType("Right operand of 'remove'", rhsType, lhsType);
    },
    execute: (model, mutableVars, lhsFref, rhsTset) => {
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
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) => `from set ${lhsSinfo.str} remove ${rhsSinfo.str}\n`
  },
  "if": {
    argAdapters: [EagerSubformula, Statements, Statements],
    validate: (mutableVars, mutableCurrentScopeVars, conditionFmla, thenBody, elseBody) => {
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
    typecheck: (model, mutableVars, conditionType, thenBody, elseBody) => {
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
    execute: (model, mutableVars, conditionTset, thenBody, elseBody) => {
      executeStatements(model, mutableVars, singleElement(conditionTset.set) ? thenBody : elseBody);
    },
    stringify: (model, mutableVars, conditionSinfo, thenBody, elseBody) => {
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
    argAdapters: [VarName, EagerSubformula, Statements],
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, domainFmla, body) => {
      mutableVars = mutableVars.shallowClone();
      mutableCurrentScopeVars = new EJSONKeyedSet();
      valAssert(!mutableVars.has(bindVarName), `foreach binding of ${bindVarName} shadows a variable defined ` + "outside the current scope (foreach block).");
      mutableCurrentScopeVars.add(bindVarName);
      mutableVars.add(bindVarName);
      validateStatements(mutableVars, mutableCurrentScopeVars, body);
    },
    typecheck: (model, mutableVars, bindVarName, domainType, body) => {
      mutableVars = mutableVars.shallowClone();
      mutableVars.add(bindVarName);  // TODO TEST THIS
      //mutableVars.set(bindVarName, domainType)
      typecheckStatements(model, mutableVars, body);
    },
    execute: (model, mutableVars, bindVarName, domainTset, body) => {
      for (let element of domainTset.elements()) {
        let newVars = mutableVars.shallowClone();
        newVars.set(bindVarName, new TypedSet(domainTset.type, set([element])));
        executeStatements(model, newVars, body);
      }
    },
    stringify: (model, mutableVars, bindVarSinfo, domainSinfo, body) => {
      mutableVars = mutableVars.shallowClone();
      mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, domainSinfo.formula));
      return `foreach (${bindVarSinfo.str} : ${domainSinfo.str}) {\n` + indent(stringifyStatements(model, mutableVars, body)) + "}\n";
    }
  },
  "delete": {
    argAdapters: [EagerSubformula],
    typecheck: (model, mutableVars, objectsType) => {
      // XXX Duplicating functionality of EagerSubformulaCells in formulas.coffee.
      // It's not worth providing a whole EagerSubformulaCells wrapper yet.
      valAssert(typeIsReference(objectsType), `Expected a set of cells, got set of '${objectsType}'`);
    },
    execute: (model, mutableVars, objectsTset) => {
      // XXX: We are relying on objectsTset.type being correct!  This
      // functionality is poorly tested since we introduced typechecking.
      model.invalidateDataCache();
      for (let objectId of objectsTset.elements()) {
        recursiveDeleteStateCellNoInvalidate(objectsTset.type, objectId);
      }
    },
    stringify: (model, mutableVars, objectsSinfo) => `delete ${objectsSinfo.str}\n`
  },
  "new": {
    argAdapters: [OptionalVarName, new EagerFamilyRef(true, false)],
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, fref) => {
      if (bindVarName != null) {
        validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName);
      }
    },
    typecheck: (model, mutableVars, bindVarName, familyType) => {
      if (bindVarName != null) {
        mutableVars.set(bindVarName, familyType);
      }
    },
    execute: (model, mutableVars, bindVarName, fref) => {
      model.invalidateDataCache();
      let objects = [];
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
        mutableVars.set(bindVarName, new TypedSet(fref.columnId, set(objects)));
      }
    },
    stringify: (model, mutableVars, bindVarSinfo, frefSinfo) => {
      if (bindVarSinfo != null) {
        mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula));
      }
      return (bindVarSinfo != null ? `let ${bindVarSinfo.str} = ` : "") + `new ${frefSinfo.str}\n`;
    }
  },
  make: {
    argAdapters: [OptionalVarName, new EagerFamilyRef(true, true)],
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, fref) => {
      if (bindVarName != null) {
        validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName);
      }
    },
    typecheck: (model, mutableVars, bindVarName, familyType) => {
      if (bindVarName != null) {
        mutableVars.set(bindVarName, familyType);
      }
    },
    execute: (model, mutableVars, bindVarName, fref) => {
      model.invalidateDataCache();
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
        mutableVars.set(bindVarName, new TypedSet(fref.columnId, set(objects)));
      }
    },
    stringify: (model, mutableVars, bindVarSinfo, frefSinfo) => {
      if (bindVarSinfo != null) {
        mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula));
      }
      return (bindVarSinfo != null ? `let ${bindVarSinfo.str} = ` : "") + `make ${frefSinfo.str}\n`;
    }
  },
  check: {
    argAdapters: [EagerSubformula],
    typecheck: (model, mutableVars, conditionType) => {
      valExpectType("check condition", conditionType, "bool");
    },
    execute: (model, mutableVars, conditionTset) => {
      if (!singleElement(conditionTset.set)) {
        throw new EvaluationError("check condition failed");
      }
    },
    stringify: (model, mutableVars, conditionSinfo) => `check ${conditionSinfo.str}\n`
  }
};

function mergeTypeMaps(vars1, vars2) {
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

function paramsToTypeMap(params) {
  return new EJSONKeyedMap(params.map((p) => [p.name, p.type]));
}

// params must already be in final format.
this.parseProcedure = (stringProc) => {
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
    let [this.varsPreviousBranch, this.vars] = this.varsStack.pop();
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
};

// Based on validateSubformula
// mutableVars: EJSONKeyedSet<string>
//
// Does not use dispatchStatement for the same reasons as validateSubformula.
function validateStatement(mutableVars, mutableCurrentScopeVars, statement) {
  var opName;
  valAssert(_.isArray(statement), "Statement must be an array.");
  valAssert(_.isString(opName = statement[0]), "Statement must begin with an operation name (a string).");
  valAssert(dispatch.hasOwnProperty(opName), `Unknown operation '${opName}'`);
  let d = dispatch[opName];
  let args = statement.slice(1);
  valAssert(args.length === d.argAdapters.length, `Wrong number of arguments to '${opName}' (required ${d.argAdapters.length}, got ${args.length})`);
  d.argAdapters.forEach((adapter, i) => {
    if (adapter.validate != null) {
      adapter.validate(mutableVars, mutableCurrentScopeVars, args[i]);
    }
  });
  if (d.validate != null) {
    d.validate.apply(d, [mutableVars, mutableCurrentScopeVars].concat(args));
  }
}

// Copied from formulas.coffee.  More generality than we need right now.
function dispatchStatement(action, statement, ...contextArgs) {
  let d = dispatch[statement[0]];
  let args = statement.slice(1);
  let adaptedArgs = d.argAdapters.map((adapter, i) => adapter[action] != null ? adapter[action].apply(adapter, contextArgs.concat([args[i]])) : args[i]);
  d[action].apply(d, contextArgs.concat(adaptedArgs));
}

function validateStatements(mutableVars, mutableCurrentScopeVars, arg) {
  valAssert(_.isArray(arg), "Expected a list of statements");
  for (let statement of arg) {
    validateStatement(mutableVars, mutableCurrentScopeVars, statement);
  }
}

function typecheckStatements(model, mutableVars, arg) {
  for (let statement of arg) {
    dispatchStatement("typecheck", statement, model, mutableVars);
  }
}

function executeStatements(model, mutableVars, arg) {
  for (let statement of arg) {
    dispatchStatement("execute", statement, model, mutableVars);
  }
}

function stringifyStatements(model, mutableVars, arg) {
  return (arg.map((statement) => dispatchStatement("stringify", statement, model, mutableVars))).join("");
}

this.validateProcedure = (proc) => {
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
};

// Returns nothing.  (If in the future we have procedures that return values,
// typecheckProcedure would return the procedure's return type.)
this.typecheckProcedure = (model, proc) => {
  let mutableVars = new EJSONKeyedMap();
  for (let param of proc.params) {
    // XXX Duplicates logic from {Type,ColumnId}.typecheck
    if (typeIsReference(param.type)) {
      valAssert(model.getColumn(param.type) != null, `No column exists with ID ${param.type}`);
    }
    mutableVars.set(param.name, param.type);
  }
  typecheckStatements(model, mutableVars, proc.body);
};

// It is assumed that the procedure already passed typecheckProcedure against the
// current schema.
//
// May throw EvaluationError and leave the sheet in an intermediate state.
this.executeProcedure = (model, proc, args) => {
  // TODO Validate correct set of arguments present with correct types?
  // Currently we consider that the caller's responsibility.
  for (let param of proc.params) {
    if (param.singular) {
      singleElement(args.get(param.name).set);  // Better error message?
    }
  }
  executeStatements(model, args.shallowClone(), proc.body);
};

this.stringifyProcedure = (proc) => {
  // C.f. stringifyFormula
  return {
    name: proc.name,
    params: EJSON.clone(proc.params),
    body: stringifyStatements(liteModel, paramsToTypeMap(proc.params), proc.body)
  };
};
