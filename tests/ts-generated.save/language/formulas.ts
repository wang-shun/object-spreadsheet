// A smidgen of user documentation:
//
// The current representation of formulas follows the style of Lisp in the format
// of JSON.  A formula is an array in which the first element is a string giving
// the name of a supported operation.  The formats and meanings of any remaining
// elements depend on the operation; they may include subformulas.  Each
// operation is briefly documented in "dispatch" below.
//
// A (sub)formula is evaluated with respect to a mapping of variable names
// (strings) to values.  At this time, the value of a variable or a subformula
// (assuming no runtime evaluation error occurs) is always a finite "typed set",
// though some operations deal exclusively with singleton sets.  The formula of
// a formula column is evaluated once for each cell in the parent column, with
// "this" bound to that parent cell, and the returned set gives the values of
// cells to generate in a "family" in the formula column.  Some operations may
// evaluate subformulas with additional variable bindings.

// Support delayed evaluation of messages that might fail to evaluate in cases
// where the assertion passes.

this.valAssert = (cond, message) => {
  if (!cond) {
    throw new FormulaValidationError(_.isString(message) ? message : message());
  }
};

function evalAssert(cond, message) {
  if (!cond) {
    throw new EvaluationError(_.isString(message) ? message : message());
  }
}

function readFamilyForFormula(model, qFamilyId) {
  let tset = model.evaluateFamily(qFamilyId);
  if (tset != null) {
    return tset;
  } else {
    // Includes the case of a newly detected cycle.
    // Future: Specifically state that there was a cycle.
    let targetTset = new TypedSet(getColumn(qFamilyId.columnId).parent, set([qFamilyId.cellId]));
    throw new EvaluationError(`Reference to column '${stringifyColumnRef([qFamilyId.columnId, true])}' of ` + `object '${tsetToTextIgnoreErrors(targetTset)}', which failed to evaluate`);
  }
}

// Based on model.evaluateFamily{,1}.
// TODO: Assuming we do want the client to be able to evaluate formulas (for now
// at least), factor out that code so the client can use it in read-only mode.
function evaluateFamilyReadOnly(qFamilyId) {
  let keyFields = {
    column: qFamilyId.columnId,
    key: qFamilyId.cellId
  };
  let ce = Cells.findOne(keyFields);
  if (ce == null) {
    let col = this.getColumn(qFamilyId.columnId);
    if (col.formula != null) {
      throw new Error(`Computed family ${qFamilyId} missing from database`);
    } else {
      return new TypedSet(col.type);
    }
  }
  if (ce.values != null) {
    return new TypedSet(this.getColumn(qFamilyId.columnId).type, new EJSONKeyedSet(ce.values));
  } else {
    return null;
  }
}

function readColumnTypeForFormula(model, columnId) {
  let type = model.typecheckColumn(columnId);
  valAssert(type != null, "column '${columnId}': type missing");
  valAssert(type !== TYPE_ERROR, `Reference to column '${stringifyColumnRef([columnId, true])}' of unknown type.  ` + "Correct its formula or manually specify the type if needed to break a cycle.");
  valAssert(type !== "_token", `Attempted to access keys of unkeyed object type '${stringifyColumnRef([columnId, false])}'.`);
  return type;
}

this.valExpectType = (what, actualType, expectedType) => {
  valAssert(commonSupertype(actualType, expectedType) === expectedType, `${what} has type '${actualType}', wanted '${expectedType}'`);
};

this.singleElement = (set) => {
  let elements = set.elements();
  evalAssert(elements.length === 1, "Expected a singleton");
  return elements[0];
};

class FormulaEngine {
  public goUpMemo;
  public compiled;

  constructor() {
    this.goUpMemo = new Memo;
    this.compiled = {};
  }

  public readFamily(column, key) {
    // FIXME propagate errors
    // TODO merge with readFamilyForFormula
    return (Cells.findOne({
      column: column,
      key: key
    }) != null ? Cells.findOne({
      column: column,
      key: key
    }).values : null) || [];
  }

  public calcLevelsUp(sourceColId, targetColId) {
    return this.goUpMemo.get(`${sourceColId}-${targetColId}`, () => {
      let [upPath, downPath] = findCommonAncestorPaths(sourceColId, targetColId);
      return upPath.length - 1;
    });
  }

  public invalidateSchemaCache() {
    this.goUpMemo.clear();
    this.compiled = {};
  }
}

// Argument adapters to reduce the amount of duplicated work to validate
// arguments and evaluate subexpressions.
// Future: Errors should pinpoint the offending subformula.
let EagerSubformula = {
  // Note, we can't eta-contract these because the functions aren't defined at
  // this point in the file.  Better ideas welcome.
  validate: (vars, arg) => {
    validateSubformula(vars, arg);
  },
  typecheck: (model, vars, arg) => typecheckFormula(model, vars, arg),
  evaluate: (model, vars, arg) => evaluateFormula(model, vars, arg),
  stringify: (model, vars, arg) => stringifySubformula(model, vars, arg),
  getSubformulas: (arg) => [arg]
};
let OptionalEagerSubformula = {
  validate: (vars, arg) => {
    if (arg != null) {
      validateSubformula(vars, arg);
    }
  },
  typecheck: (model, vars, arg) => arg != null ? typecheckFormula(model, vars, arg) : null,
  evaluate: (model, vars, arg) => arg != null ? evaluateFormula(model, vars, arg) : null,
  stringify: (model, vars, arg) => arg != null ? stringifySubformula(model, vars, arg) : null,
  getSubformulas: (arg) => arg != null ? [arg] : []
};
let EagerSubformulaCells = {
  validate: EagerSubformula.validate,
  typecheck: (model, vars, arg) => {
    let type = typecheckFormula(model, vars, arg);
    // stringifyType(type) fails if type is the root.
    valAssert(typeIsReference(type), () => `Expected a set of cells, got set of '${stringifyType(type)}'`);
    return type;
  },
  evaluate: EagerSubformula.evaluate,
  stringify: EagerSubformula.stringify,
  getSubformulas: EagerSubformula.getSubformulas
};
let HomogeneousEagerSubformulaList = {
  validate: (vars, arg) => {
    valAssert(_.isArray(arg), "Expected a list of subformulas");
    for (let item of arg) {
      validateSubformula(vars, item);
    }
  },
  typecheck: (model, vars, termFmlas) => {
    let typeSoFar = TYPE_EMPTY;
    for (let fmla of termFmlas) {
      let termType = typecheckFormula(model, vars, fmla);
      let newType = commonSupertype(typeSoFar, termType);
      valAssert(newType !== TYPE_ERROR, `Mismatched types in list: '${stringifyType(typeSoFar)}' and '${stringifyType(termType)}'`);
      typeSoFar = newType;
    }
    return typeSoFar;
  },
  evaluate: (model, vars, termFmlas) => termFmlas.map((fmla) => evaluateFormula(model, vars, fmla)),
  stringify: (model, vars, termFmlas) => termFmlas.map((fmla) => stringifySubformula(model, vars, fmla)),
  getSubformulas: (termFmlas) => termFmlas
};
let LazySubformula = {
  validate: EagerSubformula.validate,
  typecheck: EagerSubformula.typecheck,
  // No evaluate.
  stringify: EagerSubformula.stringify,
  getSubformulas: EagerSubformula.getSubformulas
};
// It might be nicer on the users to not require the extra 2-element array in the
// input, but for now this goes with our framework.
let Lambda = {
  validate: (vars, arg) => {
    valAssert(_.isArray(arg) && arg.length === 2, "Lambda subformula must be a two-element array");
    let [varName, body] = arg;
    valAssert(_.isString(varName), "Bound variable must be a string");
    // Try to save users from themselves.
    valAssert(!vars.has(varName), `Bound variable '${varName}' shadows an outer variable of the same name`);
    let newVars = vars.shallowClone();
    newVars.add(varName);
    validateSubformula(newVars, body);
  },
  typecheck: (model, vars, [varName, body]) => (argType) => {
      let newVars = vars.shallowClone();
      newVars.set(varName, argType);
      return typecheckFormula(model, newVars, body);
    },
  evaluate: (model, vars, [varName, body]) => {
    // he he he!
    return (arg) => {
      let newVars = vars.shallowClone();
      newVars.set(varName, arg);
      return evaluateFormula(model, newVars, body);
    };
  },
  stringify: (model, vars, [varName, body]) => (argType) => {
      let newVars = vars.shallowClone();
      newVars.set(varName, argType);
      return [stringifyIdent(varName), stringifySubformula(model, newVars, body)];
    },
  getSubformulas: ([varName, body]) => [body]
};
let ColumnId = {
  validate: (vars, arg) => {
    valAssert(_.isString(arg), "Column ID must be a string");
  },
  typecheck: (model, vars, arg) => {
    // XXX: Disallow the root column and add a special case for '$'?
    valAssert(model.getColumn(arg) != null, `No column exists with ID '${arg}'`);
    return arg;
  }
};
let String = {
  validate: (vars, arg) => {
    valAssert(_.isString(arg), "Must be a string");
  },
  typecheck: (model, vars, arg) => arg
};
let Type = {
  validate: (vars, arg) => {
    valAssert(_.isString(arg), "Type must be a string");
    // Future: Reject unknown primitive types
    //if !typeIsReference(arg) ...
  },
  typecheck: (model, vars, arg) => {
    if (typeIsReference(arg)) {
      ColumnId.typecheck(model, vars, arg);
    }
    return arg;
  }
};

function getValues(model, cells) {
  // XXX: Fail on token columns
  let type = model.typecheckColumn(cells.type);
  return new TypedSet(type, set(cells.elements().map((x) => cellIdLastStep(x))));
}

function typecheckUp(model, vars, startCellsType, targetColId, wantValues) {
  let [upPath, downPath] = findCommonAncestorPaths(startCellsType, targetColId);
  valAssert(downPath.length === 1, "Navigation from " + startCellsType + " to " + targetColId + " is not up");
  // Enforce the same rule as parsing.  Otherwise, if the startCellsType changes
  // as a result of a change to another formula, users will be surprised when a
  // formula that we didn't allow them to enter evaluates successfully.
  valAssert(!wantValues || upPath.length === 1, "Direct navigation up to a key of a parent object is not allowed.");
  return wantValues ? readColumnTypeForFormula(model, targetColId) : targetColId;
}

function typecheckDown(model, vars, startCellsType, targetColId, keysType, wantValues) {
  let targetCol = model.getColumn(targetColId);
  valAssert(targetCol.parent === startCellsType, "Navigation from " + startCellsType + " to " + targetColId + " is not down");
  valAssert(wantValues || targetCol.isObject, "Target column has no object type to navigate to.");
  if (keysType != null) {
    valAssert(!wantValues, "Can only specify keys when navigating to objects.");
    valExpectType("Key set", keysType, readColumnTypeForFormula(model, targetColId));
  }
  return wantValues ? readColumnTypeForFormula(model, targetColId) : targetColId;
}

function goUp(model, vars, startCellsTset, targetColId, wantValues) {
  // XXX: Can we get here with startCellsTset.type == TYPE_EMPTY?

  // Go up.
  if (startCellsTset.type === targetColId) {
    let result = startCellsTset;
  } else {
    let numIdStepsToDrop = $$.formulaEngine.goUpMemo.get(`${startCellsTset.type}-${targetColId}`, () => {
      let [upPath, downPath] = findCommonAncestorPaths(startCellsTset.type, targetColId);
      return upPath.length - 1;
    });
    let s = set();
    for (let startCellId of startCellsTset.set.elements()) {
      let targetCellId = startCellId.slice(0, startCellId.length - numIdStepsToDrop);
      // Duplicates are thrown out.  Future: multisets?
      s.add(targetCellId);
    }
    result = new TypedSet(targetColId, s);
  }

  return wantValues ? getValues(model, result) : result;
}

function goDown(model, vars, startCellsTset, targetColId, keysTset, wantValues) {
  // XXX: Can we get here with startCellsTset.type == TYPE_EMPTY?

  // Go down.
  let targetCellsSet = new EJSONKeyedSet();
  for (let cellId of startCellsTset.elements()) {
    for (let value of readFamilyForFormula(model, {
      columnId: targetColId,
      cellId: cellId
    }).elements()) {
      if ((keysTset == null) || keysTset.set.has(value)) {
        targetCellsSet.add(cellIdChild(cellId, value));
      }
    }
  }
  let targetCellsTset = new TypedSet(targetColId, targetCellsSet);

  return wantValues ? getValues(model, targetCellsTset) : targetCellsTset;
}

// Even now that we only support a reference display column (not an arbitrary
// formula), there's still a risk of infinite recursion because we allow the user
// to choose a reference display column that contains another reference, which
// we'd have to convert to text.  Ideally we'd bring the toText of each object
// into the data cache so we could stop infinite recursion the same way we do for
// formulas in general.  But I don't know how long we'll be keeping this
// functionality, so for now I'm using the refsSeen set because it's easy.
//
// refsSeen contains qCellIds.  Since we have to use the equivalent of
// EJSON.equals to compare them, we use an EJSONKeyedSet rather than implementing
// our own list membership test.
this.valueToText = (model, type, value, refsSeen : any = new EJSONKeyedSet()) => {
  if (typeIsReference(type)) {
    let qCellId = {
      columnId: type,
      cellId: value
    };
    if (refsSeen.has(qCellId)) {
      // C.f. readFamilyForFormula
      throw new EvaluationError("Circular dependency while converting object of type " + `'${stringifyType(type)}', ID ${JSON.stringify(value)}, to text`);
    }
    let newRefsSeen = refsSeen.shallowClone();
    newRefsSeen.add(qCellId);
    let col = model.getColumn(type);
    let displayColId = fallback(col.referenceDisplayColumn, defaultReferenceDisplayColumn(col));
    if (displayColId === null) {
      // Really nothing we can use?
      return "<reference>";
    } else if (displayColId === type && col.type !== "_token") {
      // The key of a keyed object.
      let displayTset = getValues(model, new TypedSet(type, set([value])));
    } else if (col.children.indexOf(displayColId) >= 0 && !model.getColumn(displayColId).isObject) {
      displayTset = readFamilyForFormula(model, {
        columnId: displayColId,
        cellId: value
      });
    } else {
      throw new EvaluationError(`Invalid reference display column for type '${stringifyType(type)}'`);
    }
    return tsetToText(model, displayTset, newRefsSeen);
  } else   return typeof value === "string" ? value : value instanceof Date ? value.toString("yyyy-MM-dd HH:mm") : JSON.stringify(value);  // Reasonable fallback
};

this.genericSetToText = (elements, formatOne) => elements.length === 1 ? formatOne(elements[0]) : "{" + (elements.map((e) => formatOne(e))).join(", ") + "}";

function tsetToText(model, tset, refsSeen : any = new EJSONKeyedSet()) {
  return genericSetToText(tset.elements(), (e) => valueToText(model, tset.type, e, refsSeen));
}

// The ignoreErrors versions must not be used in formula evaluation, because the
// ability to catch errors makes evaluation of cyclic dependencies
// nondeterministic in the current implementation.
//
// Note: Callers for major tool features should rather catch the error themselves
// and display it.  Ignoring it is OK for niche purposes like referring to values
// in an error message.

this.valueToTextIgnoreErrors = (type, value) => {
  try {
    return valueToText(liteModel, type, value);
  } catch (e) {
    return "<?>";
  }
};

this.tsetToTextIgnoreErrors = (tset) => genericSetToText(tset.elements(), (e) => valueToTextIgnoreErrors(tset.type, e));

function annotateNavigationTarget(model, vars, startCellsFmla, targetName, keysFmla, expectedFmla) {
  if (targetName == null) {
    return "(unnamed)";
  } else {
    // Future: Distinguish between "the original interpretation is no longer
    // valid" (in which case the formula should fail to typecheck) and "there are
    // multiple possible interpretations including the original" (in which case
    // the formula should still work).
    try {
      let actualFmla = resolveNavigation(model, vars, startCellsFmla, targetName, keysFmla);
      valAssert(EJSON.equals(actualFmla, expectedFmla), "Interpreting the concrete formula did not reproduce the existing abstract formula.");
      return stringifyNavigationStep(targetName);
    } catch (e) {
      // Notice: this happens regularly in the client when column
      // type information is wiped
      return stringifyNavigationStep(targetName) + "(problem)";
    }
  }
}

function stringifyNavigation(direction, model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues) {
  let column = getColumn(targetColumnId);
  // ?. returns undefined whether the LHS is null or undefined, but we want null
  // to match the familyReference production in language.jison.
  let keysFmla = fallback(keysSinfo != null ? keysSinfo.formula : null, null);
  let targetName = (() => {
    if (column == null) {
      return "(deleted)";
    } else {
      // Reconstruct the current subformula.  XXX: Get it a better way?
      let wantFormula = [direction, startCellsSinfo.formula, targetColumnId, wantValues];
      if (direction === "down") {
        wantFormula.splice(3, 0, keysFmla);
      }
      if (!wantValues) {
        return annotateNavigationTarget(model, vars, startCellsSinfo.formula, objectNameWithFallback(column), keysFmla, wantFormula);
      } else if (direction === "down" && column.isObject) {
        // Special case: when an object type Bar is added to a leaf column foo, we
        // want down navigations "(...).foo" to start displaying as "(...).Bar.foo"
        // without having to rewrite the abstract syntax of affected formulas.
        // Even if the first navigation in the concrete syntax is ambiguous, we
        // know what we meant and should annotate the second navigation
        // accordingly.
        //
        // The only way we reach here with keysFmla != null is if the user enters
        // an ill-typed formula like (...).foo[5] and then adds an object type.
        // (resolveNavigation does not convert (...).Bar[5].foo to a single down
        // navigation because of the keys, and it rejects (...).Bar.foo[5] with
        // "Only down navigations can be subscripted with keys".)  In that case,
        // this code displays (...).Bar.foo(problem)[5], which is reasonable.  It's
        // unclear if any deeper justification for passing the keysFmla to the
        // second navigation holds water.
        let intermediateFormula = wantFormula.slice(0, 3).concat([null, false]);
        return annotateNavigationTarget(model, vars, startCellsSinfo.formula, objectNameWithFallback(column), null, intermediateFormula) + "." + annotateNavigationTarget(model, vars, intermediateFormula, column.fieldName, keysFmla, wantFormula);
      } else {
        return annotateNavigationTarget(model, vars, startCellsSinfo.formula, column.fieldName, keysFmla, wantFormula);
      }
    }
  })();
  return {
    str: (startCellsSinfo.strFor(PRECEDENCE_NAV) === "$" ? "$" : startCellsSinfo.strFor(PRECEDENCE_NAV) === "this" ? "" : startCellsSinfo.strFor(PRECEDENCE_NAV) + ".") + targetName + (keysSinfo != null ? `[${keysSinfo.strFor(PRECEDENCE_LOWEST)}]` : ""),
    outerPrecedence: PRECEDENCE_NAV
  };
}

let PRECEDENCE_OR = 1;
let PRECEDENCE_AND = 2;
let PRECEDENCE_COMPARE = 3;
let PRECEDENCE_PLUS = 4;
let PRECEDENCE_TIMES = 5;
let PRECEDENCE_NEG = 6;
let PRECEDENCE_POW = 7;
let PRECEDENCE_NAV = 8;

let PRECEDENCE_LOWEST = PRECEDENCE_OR;
let PRECEDENCE_ATOMIC = PRECEDENCE_NAV;

let ASSOCIATIVITY_LEFT = "left";
let ASSOCIATIVITY_RIGHT = "right";
let ASSOCIATIVITY_NONE = null;

function binaryOperationStringify(symbol, precedence, associativity) {
  return (model, vars, lhsSinfo, rhsSinfo) => ({
      str: lhsSinfo.strFor(precedence + (associativity !== ASSOCIATIVITY_LEFT)) + " " + symbol + " " + rhsSinfo.strFor(precedence + (associativity !== ASSOCIATIVITY_RIGHT)),
      outerPrecedence: precedence
    });
}

// Just enough of a generalization of singletonInfixOperator for '+' string
// concatenation operator that automatically calls toText.
function infixOperator(symbol, precedence, associativity, lhsExpectedType, rhsExpectedType, resultType, evaluateFn, paramNames) {
  return {
    paramNames: fallback(paramNames, ["left", "right"]),
    argAdapters: [EagerSubformula, EagerSubformula],
    typecheck: (model, vars, lhsType, rhsType) => {
      valExpectType(`Left operand of '${symbol}'`, lhsType, lhsExpectedType);
      valExpectType(`Right operand of '${symbol}'`, rhsType, rhsExpectedType);
      return resultType;
    },
    evaluate: (model, vars, lhsTset, rhsTset) => new TypedSet(resultType, set([evaluateFn(model, lhsTset, rhsTset)])),
    stringify: binaryOperationStringify(symbol, precedence, associativity)
  };
}

function singletonInfixOperator(symbol, precedence, associativity, lhsExpectedType, rhsExpectedType, resultType, evaluateFn, paramNames) {
  function evaluateFn2(model, lhs, rhs) {
    return evaluateFn(singleElement(lhs.set), singleElement(rhs.set));
  }
  return infixOperator(symbol, precedence, associativity, lhsExpectedType, rhsExpectedType, resultType, evaluateFn2, paramNames);
}

function sameTypeSetsInfixPredicate(symbol, precedence, associativity, evaluateFn, paramNames) {
  return {
    paramNames: fallback(paramNames, ["left", "right"]),
    argAdapters: [EagerSubformula, EagerSubformula],
    typecheck: (model, vars, lhsType, rhsType) => {
      valAssert(commonSupertype(lhsType, rhsType) !== TYPE_ERROR, `Mismatched types to '${symbol}' operator: '${stringifyType(lhsType)}' and '${stringifyType(rhsType)}'`);
      return "bool";
    },
    evaluate: (model, vars, lhs, rhs) => new TypedSet("bool", new EJSONKeyedSet([evaluateFn(lhs.set, rhs.set)])),
    stringify: binaryOperationStringify(symbol, precedence, associativity)
  };
}

// Usage:
//   overloaded(paramNames,
//              [[argument-types...], handler],
//              [[argument-types...], handler], ...)
function overloaded(operator, paramNames, ...alternatives) {
  let arities = alternatives.map((a) => a[0].length);
  let minArity = Math.min.apply(Math, arities);
  let maxArity = Math.max.apply(Math, arities);
  function getHandler(argtypes) {
    for (let [decltypes, handler] of alternatives) {
      if (decltypes.length === argtypes.length && forall(zip(decltypes, argtypes), ([decltype, argtype]) => commonSupertype(decltype, argtype) === decltype)) {
        return handler;
      }
    }
  }
  return {
    paramNames: paramNames,
    argAdapters: (_.range(0, minArity).map((i) => EagerSubformula)).concat(_.range(minArity, maxArity).map((i) => OptionalEagerSubformula)),
    typecheck: (model, vars, ...argtypes) => {
      let handler = getHandler(argtypes);
      valAssert(handler != null, `No valid alternative of '${operator}' ` + `for argument types ${(argtypes.map((t) => "'" + stringifyType(t) + "'")).join(", ")}`);
      return handler.typecheck.apply(handler, [model, vars].concat(argtypes));
    },
    evaluate: (model, vars, ...args) => {
      let argtypes = args.map((ts) => ts.type);
      let handler = getHandler(argtypes);
      valAssert(handler != null, `No valid alternative of '${operator}' ` + `for argument types ${(argtypes.map((t) => "'" + stringifyType(t) + "'")).join(", ")}`);
      return handler.evaluate.apply(handler, [model, vars].concat(args));
    },
    stringify: (model, vars, ...sinfos) => {
      // Does it even make sense to have different stringifies for different alternatives?
      let [_, handler] = alternatives[0];
      return handler.stringify.apply(handler, [model, vars].concat(sinfos));
    }
  };
}

function compareInfixOperator(symbol, precedence, associativity, evaluateFn) {
  return overloaded(symbol, ["left", "right"], [["number", "number"], singletonInfixOperator(symbol, precedence, associativity, "number", "number", "bool", evaluateFn)], [["date", "date"], singletonInfixOperator(symbol, precedence, associativity, "date", "date", "bool", evaluateFn)]);
}

// The definition in common.coffee is not guaranteed to load first.  I think this
// is the least evil for now. ~ Matt 2015-11-25
let TYPE_ERROR = "error";

let dispatch = {
  // ["lit", type ID (string), elements (array)]:
  // A literal set of elements of the specified type.
  // Concrete syntax: 2, {3,4}, {5,6,7,} etc.  The elements may be JSON booleans,
  // numbers, or strings.
  // XXX: Now that we have union, we could change lit to accept only a single
  // element, but that will break existing abstract formulas.  Maybe do it
  // if/when we add data type validation?
  lit: {
    argAdapters: [Type, {}],
    validate: (vars, type, list) => {
      valAssert(_.isArray(list), "Set literal must be an array");
      // Future: Could go ahead and validate primitive-type literals here.
    },
    typecheck: (model, vars, type, list) => type,
    evaluate: (model, vars, type, list) => {
      // XXXXXXX: Validate members of the type.
      return new TypedSet(type, new EJSONKeyedSet(list));
    },
    stringify: (model, vars, type, list) => ({
        str: (() => {
          // Obviously, if someone manually creates a literal that requires a
          // leading minus or set notation, those constructs will be re-parsed as
          // operators rather than as part of the literal.
          if (type === "_root") {
            // See stringifyNavigation.  This shouldn't be exposed anywhere else.
            return "$";
          } else if (list.length === 1) {
            return JSON.stringify(list[0]);
          } else {
            // XXX: Canonicalize order?
            return "{" + (list.map((x) => JSON.stringify(x))).join(",") + "}";
          }
        })(),
        outerPrecedence: (() => {
          if (type === "number" && list.length === 1 && list[0] < 0) {
            // Should never be reached by parsing concrete syntax.
            return PRECEDENCE_NEG;
          } else {
            return PRECEDENCE_ATOMIC;
          }
        })()
      })
  },
  // ["date", string]
  date: {
    argAdapters: [String],
    typecheck: () => "date",
    evaluate: (model, vars, string) => new TypedSet("date", new EJSONKeyedSet([Date.parse(string)])),
    stringify: (model, vars, string) => ({
        str: `d${JSON.stringify(string)}`,
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  // ["var", varName (string)]:
  // Gets the value of a bound variable.
  // Concrete syntax: myVar
  "var": {
    argAdapters: [{}],
    validate: (vars, varName) => {
      valAssert(_.isString(varName), "Variable name must be a string");
      valAssert(vars.has(varName), `Undefined variable ${varName}`);
    },
    typecheck: (model, vars, varName) => vars.get(varName),
    evaluate: (model, vars, varName) => vars.get(varName),
    stringify: (model, vars, varName) => ({
        str: (() => {
          if (varName === "this") {
            // A 'this' reference can only occur implicitly in concrete syntax, as
            // the left operand of a navigation.  The following is just a sentinel
            // for stringifyNavigation.
            return "this";
          } else {
            return annotateNavigationTarget(model, vars, null, varName, null, ["var", varName]);
          }
        })(),
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  // ["up", startCells, targetColumnId, wantValues (bool)]
  // Concrete syntax: foo, FooCell, (expression).foo, etc.
  up: {
    paramNames: ["start", null, null],
    argAdapters: [EagerSubformulaCells, ColumnId, {}],
    validate: (vars, startCellsFmla, targetColumnId, wantValues) => {
      valAssert(_.isBoolean(wantValues), "wantValues must be a boolean");
    },
    typecheck: typecheckUp,
    evaluate: goUp,
    stringify: (model, vars, startCellsSinfo, targetColumnId, wantValues) => stringifyNavigation("up", model, vars, startCellsSinfo, targetColumnId, null, wantValues)
  },
  // ["down", startCells, targetColumnId, wantValues (bool)]
  // Currently allows only one step, matching the concrete syntax.  This makes
  // life easier for now.
  // XXX: Eventually the easiest way to provide the refactoring support we'll
  // want is to allow multiple steps.  We can see the issue already if startCells
  // changes type from one ancestor of the target column to another, e.g.,
  // because it is reading from another column whose formula changed.
  // Concrete syntax: foo, FooCell, (expression).foo, ::Bar, etc.
  down: {
    paramNames: ["start", null, "keys", null],
    argAdapters: [EagerSubformulaCells, ColumnId, OptionalEagerSubformula, {}],
    validate: (vars, startCellsFmla, targetColumnId, keysFmla, wantValues) => {
      valAssert(_.isBoolean(wantValues), "wantValues must be a boolean");
    },
    typecheck: typecheckDown,
    evaluate: goDown,
    stringify: (model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues) => stringifyNavigation("down", model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues)
  },
  // ["if", condition, thenFmla, elseFmla]
  // Concrete syntax: if(condition, thenFmla, elseFmla)
  // (Can we think of a better concrete syntax?)
  "if": {
    paramNames: ["condition", "thenExpr", "elseExpr"],
    argAdapters: [EagerSubformula, LazySubformula, LazySubformula],
    typecheck: (model, vars, conditionType, thenType, elseType) => {
      valExpectType("if condition", conditionType, "bool");
      let type = commonSupertype(thenType, elseType);
      valAssert(type !== TYPE_ERROR, `Mismatched types in if branches: '${stringifyType(thenType)}' and '${stringifyType(elseType)}'`);
      return type;
    },
    evaluate: (model, vars, conditionTset, thenFmla, elseFmla) => evaluateFormula(model, vars, singleElement(conditionTset.set) ? thenFmla : elseFmla),
    stringify: (model, vars, conditionSinfo, thenSinfo, elseSinfo) => ({
        str: `if(${conditionSinfo.strFor(PRECEDENCE_LOWEST)}, ${thenSinfo.strFor(PRECEDENCE_LOWEST)}, ${elseSinfo.strFor(PRECEDENCE_LOWEST)})`,
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  count: {
    paramNames: ["set"],
    argAdapters: [EagerSubformula],
    typecheck: (model, vars, domainType) => "number",
    evaluate: (model, vars, domainTset) => new TypedSet("number", set([domainTset.elements().length])),
    stringify: (model, vars, domainSinfo) => ({
        // TODO: Factor out helper for function syntax.
        str: `count(${domainSinfo.strFor(PRECEDENCE_LOWEST)})`,
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  oneOf: {
    paramNames: ["set"],
    argAdapters: [EagerSubformula],
    typecheck: (model, vars, domainType) => domainType,
    evaluate: (model, vars, domainTset) => {
      evalAssert(domainTset.elements().length > 0, "oneOf on empty set.");
      return new TypedSet(domainTset.type, set([domainTset.elements()[0]]));
    },
    stringify: (model, vars, domainSinfo) => ({
        str: `oneOf(${domainSinfo.strFor(PRECEDENCE_LOWEST)})`,
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  // ["filter", domain (subformula), [varName, predicate (subformula)]]:
  // For each cell in the domain, evaluates the predicate with varName bound to
  // the domain cell, which must return a singleton boolean.  Returns the set of
  // domain cells for which the predicate returned true.
  // Concrete syntax: {x : expr | predicate}
  filter: {
    paramNames: ["set", "predicate"],
    argAdapters: [EagerSubformula, Lambda],
    typecheck: (model, vars, domainType, predicateLambda) => {
      let predicateType = predicateLambda(domainType);
      valExpectType("Predicate", predicateType, "bool");
      return domainType;
    },
    evaluate: (model, vars, domainTset, predicateLambda) => {
      // XXX Use the checked type instead?
      return new TypedSet(domainTset.type, new EJSONKeyedSet(_.filter(domainTset.set.elements(), (x) => {
        // Future: Figure out where to put this code once we start duplicating it.
        let tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]));
        return singleElement(predicateLambda(tset).set);
      })));
    },
    stringify: (model, vars, domainSinfo, predicateLambda) => {
      // XXX Wasteful
      let predicateSinfo = predicateLambda(tryTypecheckFormula(model, vars, domainSinfo.formula));
      return {
        str: `{${predicateSinfo[0]} : ${domainSinfo.strFor(PRECEDENCE_LOWEST)} ` + `| ${predicateSinfo[1].strFor(PRECEDENCE_LOWEST)}}`,
        outerPrecedence: PRECEDENCE_ATOMIC
      };
    }
  },
  sum: {
    paramNames: ["domain", "function"],
    argAdapters: [EagerSubformula, Lambda],
    typecheck: (model, vars, domainType, addendLambda) => {
      let addendType = addendLambda(domainType);
      valExpectType("Element of 'sum'", addendType, "number");
      return "number";
    },
    evaluate: (model, vars, domainTset, addendLambda) => {
      let res = 0;
      for (let x of domainTset.elements()) {
        let tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]));
        res += singleElement(addendLambda(tset).set);
      }
      return new TypedSet("number", new EJSONKeyedSet([res]));
    },
    stringify: (model, vars, domainSinfo, addendLambda) => {
      let addendSinfo = addendLambda(tryTypecheckFormula(model, vars, domainSinfo.formula));
      return {
        str: `sum[${addendSinfo[0]} : ${domainSinfo.strFor(PRECEDENCE_LOWEST)}]` + `(${addendSinfo[1].strFor(PRECEDENCE_LOWEST)})`,
        outerPrecedence: PRECEDENCE_ATOMIC
      };
    }
  },
  // Predicates on two sets of the same type.
  "=": sameTypeSetsInfixPredicate("=", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, EJSON.equals),
  "!=": sameTypeSetsInfixPredicate("!=", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) => !EJSON.equals(x, y)),
  "in": sameTypeSetsInfixPredicate("in", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, ((x, y) => y.hasAll(x)), ["needle", "haystack"]),
  // Unary minus.
  "neg": {
    paramNames: ["expr"],
    argAdapters: [EagerSubformula],
    typecheck: (model, vars, argType) => {
      valExpectType("Operand of unary '-'", argType, "number");
      return "number";
    },
    evaluate: (model, vars, arg) => new TypedSet("number", set([-singleElement(arg.set)])),
    stringify: (model, vars, argSinfo) => ({
        str: `-${argSinfo.strFor(PRECEDENCE_NEG)}`,
        outerPrecedence: PRECEDENCE_NEG
      })
  },
  // XXX Since we look at one binary operation at a time and '+' is left
  // associative, "foo" + 3 + 5 is "foo35" but 3 + 5 + "foo" is "8foo".  Java
  // is the same way, but we could do better for users who are unaware of this
  // subtlety by making '+' variadic in the abstract syntax.  This is a rare
  // case because string concatenations will usually include a delimiter.  Or
  // we could just use a different operator for string concatenation.
  //
  // XXX TYPE_ERROR is a misnomer in this context: it means we accept tsets of
  // any valid type.  (There's no way to write a subexpression that actually
  // returns TYPE_ERROR; instead it will cause a FormulaValidationError.)
  "+": overloaded("+", ["left", "right"], [["number", "number"], singletonInfixOperator("+", PRECEDENCE_PLUS, ASSOCIATIVITY_LEFT, "number", "number", "number", (x, y) => x + y)], [[TYPE_ERROR, TYPE_ERROR], infixOperator("+", PRECEDENCE_PLUS, ASSOCIATIVITY_LEFT, TYPE_ERROR, TYPE_ERROR, "text", (model, tsetX, tsetY) => tsetToText(model, tsetX) + tsetToText(model, tsetY))]),
  "-": singletonInfixOperator("-", PRECEDENCE_PLUS, ASSOCIATIVITY_LEFT, "number", "number", "number", (x, y) => x - y),
  "*": singletonInfixOperator("*", PRECEDENCE_TIMES, ASSOCIATIVITY_LEFT, "number", "number", "number", (x, y) => x * y),
  "/": singletonInfixOperator("/", PRECEDENCE_TIMES, ASSOCIATIVITY_LEFT, "number", "number", "number", (x, y) => x / y),
  "^": singletonInfixOperator("^", PRECEDENCE_POW, ASSOCIATIVITY_RIGHT, "number", "number", "number", Math.pow, ["base", "exponent"]),
  "<": compareInfixOperator("<", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) => x < y),
  "<=": compareInfixOperator("<=", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) => x <= y),
  ">": compareInfixOperator(">", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) => x > y),
  ">=": compareInfixOperator(">=", PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) => x >= y),
  // TODO: Short circuit?
  "&&": singletonInfixOperator("&&", PRECEDENCE_AND, ASSOCIATIVITY_LEFT, "bool", "bool", "bool", (x, y) => x && y),
  "||": singletonInfixOperator("||", PRECEDENCE_OR, ASSOCIATIVITY_LEFT, "bool", "bool", "bool", (x, y) => x || y),
  "!": {
    paramNames: ["condition"],
    argAdapters: [EagerSubformula],
    typecheck: (model, vars, argType) => {
      valExpectType("Operand of '!'", argType, "bool");
      return "bool";
    },
    evaluate: (model, vars, arg) => new TypedSet("bool", set([!singleElement(arg.set)])),
    stringify: (model, vars, argSinfo) => ({
        str: `!${argSinfo.strFor(PRECEDENCE_NEG)}`,
        outerPrecedence: PRECEDENCE_NEG
      })
  },
  // ["union", list of subformulas]
  // Union of a fixed number of sets.
  union: {
    paramNames: ["part"],  // Will be expanded by getSubformulaTree
    argAdapters: [HomogeneousEagerSubformulaList],
    typecheck: (model, vars, termsType) => termsType,
    evaluate: (model, vars, terms) => {
      let res = new TypedSet();
      for (let term of terms) {
        res.addAll(term);
      }
      return res;
    },
    stringify: (model, vars, termSinfos) => ({
        str: "{" + (termSinfos.map((termSinfo) => termSinfo.strFor(PRECEDENCE_LOWEST))).join(", ") + "}",
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  dummy: {
    paramNames: [],
    argAdapters: [],
    typecheck: (model, vars) => TYPE_EMPTY,
    evaluate: (model, vars) => new TypedSet(),
    stringify: (model, vars) => ({
        // DUMMY_FORMULA is treated specially in the formula bar.  The following is
        // in case it shows up somewhere else in the system.
        str: "dummy",
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  },
  toText: {
    paramNames: ["expr"],
    argAdapters: [EagerSubformula],
    typecheck: (model, vars, argType) => "text",
    evaluate: (model, vars, arg) => new TypedSet("text", set([tsetToText(model, arg)])),
    stringify: (model, vars, argSinfo) => ({
        str: `toText(${argSinfo.strFor(PRECEDENCE_LOWEST)})`,
        outerPrecedence: PRECEDENCE_ATOMIC
      })
  }
};

// Catches syntax errors, references to nonexistent bound variables, and
// variable shadowing, but not anything related to schema, data, or types.
// vars: EJSONKeyedSet<string>
//
// This is just different enough from dispatchSubformula not to use it.
// Specifically, the validate method of the operation is optional, and it
// receives the original arguments (the adapters do not return values).
function validateSubformula(vars, formula) {
  var opName;
  valAssert(_.isArray(formula), "Subformula must be an array.");
  valAssert(_.isString(opName = formula[0]), "Subformula must begin with an operation name (a string).");
  valAssert(dispatch.hasOwnProperty(opName), `Unknown operation '${opName}'`);
  let d = dispatch[opName];
  let args = formula.slice(1);
  valAssert(args.length === d.argAdapters.length, `Wrong number of arguments to '${opName}' (required ${d.argAdapters.length}, got ${args.length})`);
  d.argAdapters.forEach((adapter, i) => {
    if (adapter.validate != null) {
      adapter.validate(vars, args[i]);
    }
  });
  if (d.validate != null) {
    d.validate.apply(d, [vars].concat(args));
  }
}

this.validateFormula = (formula) => {
  try {
    validateSubformula(new EJSONKeyedSet(["this"]), formula);
  } catch (e) {
    // XXX: Want to do this here?
    if (e instanceof FormulaValidationError) {
      throw new Meteor.Error("invalid-formula", "Invalid formula: " + e.message);
    } else {
      throw e;
    }
  }
};

function dispatchFormula(action, formula, ...contextArgs) {
  let d = dispatch[formula[0]];
  let args = formula.slice(1);
  let adaptedArgs = d.argAdapters.map((adapter, i) => adapter[action] != null ? adapter[action].apply(adapter, contextArgs.concat([args[i]])) : args[i]);
  return d[action].apply(d, contextArgs.concat(adaptedArgs));
}

// Assumes formula has passed validation.
// vars: EJSONKeyedMap<string, type (nullable string)>
// Returns type (nullable string).
this.typecheckFormula = (model, vars, formula) => {
  formula.vars = vars;
  return formula.type = dispatchFormula("typecheck", formula, model, vars);
};

// Helper for use in stringify, where we want to do our best rather than crash if
// the formula is ill-typed.
function tryTypecheckFormula(model, vars, formula) {
  try {
    return typecheckFormula(model, vars, formula);
  } catch (e) {
    return TYPE_EMPTY;
  }
}

// Assumes formula has passed typechecking.
// vars: EJSONKeyedMap<string, TypedSet>
this.evaluateFormula = (model, vars, formula) => {
  try {
    let result = dispatchFormula("evaluate", formula, model, vars);
  } catch (e) {
    if (e instanceof EvaluationError && model.isTracing) {
      if (formula.traces == null) {
        formula.traces = new EJSONKeyedMap();
      }
      formula.traces.set(vars, {
        error: e.message
      });
    }
    throw e;
  }
  if (model.isTracing) {
    if (formula.traces == null) {
      formula.traces = new EJSONKeyedMap();
    }
    formula.traces.set(vars, {
      result: result
    });
  }
  return result;
};

// TODO: Separate out the determination of the initial variable values so we can
// reuse the rest for formulas in procedures, etc.
this.traceColumnFormula = (formula, columnId) => {
  let tracingModel = {
    getColumn: (columnId) => getColumn(columnId),
    evaluateFamily: (qFamilyId) => evaluateFamilyReadOnly(qFamilyId),
    typecheckColumn: (columnId) => getColumn(columnId).type,
    isTracing: true
  };
  // Here we really do want to ignore erroneous families in the parent column
  // because there is nothing to trace for them.
  let parentColumnId = getColumn(columnId).parent;
  return allCellIdsInColumnIgnoreErrors(parentColumnId).map((cellId) => {
    try {
      let vars = new EJSONKeyedMap([["this", new TypedSet(parentColumnId, new EJSONKeyedSet([cellId]))]]);
      return evaluateFormula(tracingModel, vars, formula);
    } catch (e) {
      if (e instanceof EvaluationError) {
        // Ignore; already traced.
      } else {
        throw e;
      }
    }
  });
};

this.DUMMY_FORMULA = ["dummy"];
Meteor.startup(() => {
  typecheckFormula(null, null, DUMMY_FORMULA);  // Action bar looks for type field.
});  // Load order for TYPE_EMPTY

// BELOW: Concrete syntax support.  However, this is used on the server, by
// loadPTCData!

function validateAndTypecheckFormula(model, vars, formula) {
  validateSubformula(new EJSONKeyedSet(vars.keys()), formula);
  return typecheckFormula(model, vars, formula);
}

// Handle startCellsFmla.targetName or targetName by itself
// (startCellsFmla == null), which may also be a variable reference.
// vars: EJSONKeyedMap<string, type (string)>
// Returns the new formula with the call to "up" or "down" added around
// startCellsFmla.
function resolveNavigation(model, vars, startCellsFmla, targetName, keysFmla) {
  let interpretations = [];
  if (startCellsFmla == null) {
    if ((vars.get("this") != null) && typeIsReference(vars.get("this"))) {
      valAssert(targetName !== "this", "Explicit \"this\" is not allowed in concrete syntax.  " + "Please use the object name for clarity.");
      if (vars.get(targetName) != null) {
        interpretations.push(["var", targetName]);
      }
      startCellsFmla = ["var", "this"];
      /*fakeblock  // i.e., in procedures
      // Fall through to navigation interpretations.
      */
    } else {
      valAssert(vars.get(targetName) != null, `Undefined variable '${targetName}'`);
      // Currently this can only happen in procedures.
      valAssert(vars.get(targetName) !== TYPE_ERROR, `Variable '${targetName}' cannot be read because ` + "it does not have a known type at this point.");
      return ["var", targetName];
    }
  }

  // XXX: This is a lot of duplicate work reprocessing subtrees.
  let startCellsType = validateAndTypecheckFormula(model, vars, startCellsFmla);
  valAssert(startCellsType && typeIsReference(startCellsType), () => `Expected a set of cells, got set of '${stringifyType(startCellsType)}'`);

  // Check logical ancestor objects (no keys).
  // Note, it's impossible to navigate to the root column since it has no field name or
  // object name.
  let [upPath, dummyDownPath] = findCommonAncestorPaths(startCellsType, rootColumnId);
  for (let upColumnId of upPath) {
    if (objectNameWithFallback(getColumn(upColumnId)) === targetName) {
      interpretations.push(["up", startCellsFmla, upColumnId, false]);
    }
  }

  // Check logical children.
  for (let [columnId, isValues, direction] of columnLogicalChildrenByName(startCellsType, targetName)) {
    interpretations.push([direction, startCellsFmla, columnId, isValues]);
  }

  // Future: Enforce uniqueness of interpretations in any scope?
  valAssert(interpretations.length === 1, `${interpretations.length} possible interpretations for ` + `<type ${stringifyType(startCellsType)}>.${targetName}, wanted one.`);
  let formula = interpretations[0];

  if (formula[0] === "down") {
    // typecheckDown checks the rest of the requirements for subscripting.
    formula.splice(3, 0, keysFmla);
  } else {
    // We have to check this here so we don't silently ignore the subscript.
    // XXX: When navigating to a key column, this error message is inconsistent
    // with the user-facing model, in which such a navigation is down.
    valAssert(keysFmla == null, "Only down navigations can be subscripted with keys.");
  }

  // If Bar is an object type with key foo, "(...).Bar.foo" parses as
  // ['up', ['down', ..., fooID, null, false], fooID, true].  Convert to
  // ['down', ..., fooID, null, true] so it displays as "(...).foo" if the object
  // type is removed.  (Converse of the case in stringifyNavigation.)
  if (formula[0] === "up" && formula[3] && formula[1][0] === "down" && formula[1][2] === formula[2] && (formula[1][3] == null) && !formula[1][4]) {
    formula = ["down", formula[1][1], formula[2], null, true];
  }

  return formula;
}

// Fake model object that can be used by the client or the server to manipulate
// formulas "on top of" an already evaluated sheet.  (On the server, it would
// probably also be OK to use the real model object.  However, the client doesn't
// have access to the real model object under the current design.  Arguably the
// design could use improvement, but not now. ~ Matt 2015-11-20)
//
// If the client is unlucky enough to call this while the server is recomputing,
// return dummy values.  If the code is reactive, it will recover.
this.liteModel = {
  // Eta-expand to avoid load-order dependency.
  getColumn: (columnId) => getColumn(columnId),
  // FIXME: propagate errors
  evaluateFamily: (qFamilyId) => new FamilyId(qFamilyId).typedValues(),
  typecheckColumn: (columnId) => fallback(getColumn(columnId).type, TYPE_ERROR)
};

// Reused by parseProcedure. :/
this.setupParserCommon = (startToken, vars) => {
  let parser = new Jison.Parsers.language.Parser();
  parser.yy.vars = vars.shallowClone();
  parser.yy.startToken = startToken;
  parser.yy.bindVar = function(varName, formula) {
    // Don't check shadowing here, because the rules for procedures are
    // complicated.  It will be done later by the validate method.
    this.vars.set(varName, validateAndTypecheckFormula(liteModel, this.vars, formula));
  };
  parser.yy.unbindVar = function(varName) {
    this.vars["delete"](varName);
  };
  parser.yy.navigate = function(startCellsFmla, targetName, keysFmla) {
    return resolveNavigation(liteModel, this.vars, startCellsFmla, targetName, keysFmla);
  };
  parser.yy.parseError = (err, hash) => {
    throw new SyntaxError(err, hash);
  };
  return parser;
};

this.parseFormula = (thisType, fmlaString) => {
  // XXX: If we are changing a formula so as to introduce a new cyclic type
  // checking dependency, we use the old types of the other columns to interpret
  // navigations in the new formula.  However, as soon as we save, all the
  // columns in the cycle will change to TYPE_ERROR and the navigations we just
  // interpreted will become invalid.  This behavior is weird but not worth
  // fixing now.

  let parser = setupParserCommon("ENTRY_FORMULA", new EJSONKeyedMap([["this", thisType]]));

  try {
    return parser.parse(fmlaString);
  } catch (e) {
    if (e instanceof SyntaxError) {
      throw new FormulaValidationError(e.message);
    } else {
      throw e;
    }
  }
};

function stringifyIdentCommon(entryPoint, ident) {
  for (let str of [ident, `\`${ident}\``]) {
    let parser = new Jison.Parsers.language.Parser();
    parser.yy.startToken = entryPoint;
    try {
      if (parser.parse(str) === ident) {
        return str;
      }
    } catch (e) {
      // fall through
    }
  }
  // Currently I think this only happens if the identifier contains `, but it's
  // nice for the code to be future-proof. ~ Matt 2015-10-16
  throw new FormulaValidationError(`Cannot stringify identifier '${ident}'`);
}

// Special version that won't unnecessarily backquote the [key] fallback object
// name syntax.
// XXX: I guess this lets people define a variable named [foo] and then refer to
// it without backquotes in some (but not all) contexts.
function stringifyNavigationStep(ident) {
  return stringifyIdentCommon("ENTRY_NAVIGATION_STEP", ident);
}

function stringifyIdent(ident) {
  return stringifyIdentCommon("ENTRY_IDENT", ident);
}

function stringifySubformula(model, vars, formula) {
  let res = dispatchFormula("stringify", formula, model, vars);
  return {
    // Save original: used by stringifyNavigation.  (Might not be the best design.)
    formula: formula,
    strFor: (lowestSafePrecedence) => res.outerPrecedence >= lowestSafePrecedence ? res.str : `(${res.str})`
  };
}

this.stringifyFormula = (thisType, formula) => {
  // Stringify should only happen after type checking, so it can use liteModel on
  // either client or server.
  return stringifySubformula(liteModel, new EJSONKeyedMap([["this", thisType]]), formula).strFor(PRECEDENCE_LOWEST);
};

this.getSubformulaTree = (formula) => {
  let d = dispatch[formula[0]];
  let args = formula.slice(1);
  let children = [];
  d.argAdapters.forEach((adapter, i) => {
    if (adapter.getSubformulas != null) {
      let paramName = d.paramNames[i];
      let childNodes = adapter.getSubformulas(args[i]).map((f) => getSubformulaTree(f));
      children.push.apply(children, (childNodes.length !== 1 ? childNodes.map((n, j) => ({  // union, others?
          paramName: `paramName${j + 1}`,
          node: n
        })) : [
        {
          paramName: paramName,
          node: childNodes[0]
        }
      ]));
    }
  });
  return {
    formula: formula,
    children: children
  };
};

exported({
  FormulaEngine: FormulaEngine,
  FormulaInternals: {
    EagerSubformula: EagerSubformula,
    stringifyIdent: stringifyIdent,
    tryTypecheckFormula: tryTypecheckFormula,
    PRECEDENCE_LOWEST: PRECEDENCE_LOWEST
  }
});
