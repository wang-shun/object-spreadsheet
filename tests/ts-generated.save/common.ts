// Relational Spreadsheets definitions needed by both client and server that
// don't fall into a more specific file such as formulas.coffee.


namespace Objsheets {

  export var rootColumnId = "_root";

  // Multisets unsupported for now: twindex removed.

  export var rootCellId = [];
  export function cellIdParent(cellId) {
    return cellId.slice(0, -1);
  }
  export function cellIdChild(cellId, value) {
    return cellId.concat([value]);
  }
  export function cellIdLastStep(cellId) {
    return cellId[cellId.length - 1];
  }

  // N.B. Meteor.makeErrorType is the way to make a subclass of Error so that both
  // instanceof and stack traces work.

  // Careful: with "class EvaluationError", the original class gets assigned to a
  // file-scope variable that shadows the exported wrapped class seen by the rest
  // of the application, and instanceof breaks.
  class EvaluationError_ {
    constructor(public message) {}
  }
  export var EvaluationError = Meteor.makeErrorType("EvaluationError", EvaluationError_);

  // Used also for typechecking.
  class FormulaValidationError_ {
    constructor(public message) {}
  }
  export var FormulaValidationError = Meteor.makeErrorType("FormulaValidationError", FormulaValidationError_);

  class SyntaxError_ {
    constructor(public message, public details) {}
  }
  export var SyntaxError = Meteor.makeErrorType("SyntaxError", SyntaxError_);

  class SemanticError_ {
    constructor(public message) {}
  }
  export var SemanticError = Meteor.makeErrorType("SemanticError", SemanticError_);

  // Model data structures and parameters the client needs to be aware of:
  // (I tried using EJSON custom classes but it was too much of a pain to store in
  // the DB.  If I find a good solution, we could go back to using EJSON custom
  // classes. ~ Matt)

  // Column:
  //@_id
  //@parent: column ID
  //@children: array of column IDs, now in the user's desired order
  //@fieldName: string or null
  //@specifiedType: type specified by user (required for state columns)
  //@type: checked type (always set during evaluation)
  //@typecheckError: string or null, formula type checking error message
  //@isObject: boolean
  //  (We could alternatively encode this by making @children nullable.)
  //@objectName: string or null
  //@formula: some JSON data structure, or null for a state column

  export function getColumn(id) {
    return Columns.findOne(id);
  }

  export function columnIsState(col) {
    return col._id !== rootColumnId && (col.formula == null);
  }

  export function objectNameWithFallback(col) {
    return fallback(col.objectName, (col.fieldName != null ? `[${col.fieldName}]` : null));
  }

  export function columnDepth(columnId) {
    return columnId === rootColumnId ? 0 : 1 + columnDepth(getColumn(columnId).parent);
  }

  export function nextAvailableColumnName(prefix) {
    let i = 1;
    while (Columns.find({
        $or: [
          {
            fieldName: `${prefix}${i}`
          }, {
            objectName: `${prefix}${i}`
          }
        ]
      }).count() > 0) {
      i++;
    }
    return `${prefix}${i}`;
  }

  // This implements the user-facing conceptual model in which a key is a child of the object.
  // Precondition: getColumn(id).isObject == true
  // Returns: list of [child id, isValues, direction]
  // Having direction here is a little awkward but lets us reuse this in resolveNavigation.
  export function columnLogicalChildrenByName(id, wantName) {
    let col = getColumn(id);
    let ret = [];
    function visit(name, descriptor) {  // descriptor = [childId, isValues, direction]
      if (name === wantName) {
        ret.push(descriptor);
      }
    }
    visit(col.fieldName, [id, true, "up"]);
    for (let physChildCol of Columns.find({
      parent: id
    }).fetch()) {
      if (physChildCol.isObject) {
        visit(objectNameWithFallback(physChildCol), [physChildCol._id, false, "down"]);
      } else {
        visit(physChildCol.fieldName, [physChildCol._id, true, "down"]);
      }
    }
    return ret;
  }

  export function stringifyType(type) {
    return typeIsReference(type) ? stringifyColumnRef([type, false]) : type;
  }

  export function parseTypeStr(s) {
    // This is an abuse of typeIsReference, since s is a UI-level (not internal)
    // type string, but it will work to check whether s is recognized as the name
    // of a non-reference type.
    return typeIsReference(s) ? parseObjectTypeRef(s) : s;
  }

  export function parseObjectTypeRef(s) {
    let colId2 = parseColumnRef(s);
    if (colId2[1]) {
      throw new SemanticError(`'${s}' refers to a value column, not an object type.`);
    }
    return colId2[0];
  }

  // Compare to resolveNavigation.
  // Returns: [columnId, isValues]
  export function parseColumnRef(s) {
    if (!s) {
      // What we currently want for user-facing usage.  load-sample-data has to
      // override this behavior. :/
      throw new SemanticError("We currently do not support references to the root column.");
    }
    let colId2 = [rootColumnId, false];
    for (let n of s.split(":")) {
      if (colId2[1]) {
        throw new SemanticError(`Looking up child '${n}' of a value column.`);
      }
      let interpretations = columnLogicalChildrenByName(colId2[0], n);
      if (interpretations.length !== 1) {
        throw new SemanticError(`${interpretations.length} interpretations for ` + `${stringifyColumnRef(colId2)}:${n}, wanted one.`);
      }
      colId2 = interpretations[0].slice(0, 2);
    }
    return colId2;
  }

  // Compare to stringifyNavigation.
  export function stringifyColumnRef([columnId, isValues]) {
    if (columnId === rootColumnId) {
      // XXX Consider reenabling the error after more testing. ~ Matt 2015-11-25
      //throw new SemanticError('We currently do not support references to the root column.')
      return "$";
    }
    let names = [];
    while (columnId !== rootColumnId) {
      let col = getColumn(columnId);
      if (col == null) {
        return "(deleted)";
      }
      let name = isValues ? col.fieldName : objectNameWithFallback(col);
      let logicalParent = isValues && col.isObject ? columnId : col.parent;
      if (name != null) {
        if (columnLogicalChildrenByName(logicalParent, name).length !== 1) {
          name += "(ambiguous)";
        }
      } else {
        name = "(unnamed)";
      }
      names.unshift(name);
      isValues = false;
      columnId = logicalParent;
    }
    return names.join(":");
  }

  // Finds the lowest common ancestor of columnId1 and columnId2 and returns a
  // pair of arrays giving the sequences of ancestors from columnId1 and
  // columnId2 (respectively) to the common ancestor, inclusive.
  export function findCommonAncestorPaths(columnId1, columnId2) {
    var idx;
    let ancestors1 = [];
    let cid = columnId1;
    while (true) {
      ancestors1.push(cid);
      if (cid === rootColumnId) {
        break;
      }
      cid = getColumn(cid).parent;
    }
    let ancestors2 = [];
    cid = columnId2;
    while (true) {
      ancestors2.push(cid);
      // We could make this not O(N^2) if we cared...
      if ((idx = ancestors1.indexOf(cid)) !== -1) {
        break;
      }
      cid = getColumn(cid).parent;
    }
    ancestors1.splice(idx + 1, ancestors1.length - (idx + 1));
    return [ancestors1, ancestors2];
  }

  // The empty type, subtype of all other types, used for literal empty sets, etc.
  // Not allowed for state columns.
  export var TYPE_EMPTY = "empty";

  export var TYPE_ERROR = "error";

  export var MAIN_PRIMITIVE_TYPES = ["text", "number", "bool", "date"];
  export var DEFAULT_STATE_FIELD_TYPE = "text";

  // Other special types:
  // _root: reference, should never be user-visible (no concrete syntax to get at it)
  // _unit: primitive, deprecated but still used in ptc
  // _token: special primitive, should never be user-visible

  let NON_REFERENCE_TYPES = [TYPE_EMPTY, TYPE_ERROR].concat(MAIN_PRIMITIVE_TYPES);

  // It's messy to have some primitive types that begin with underscore and others
  // that don't.  We could have hidden the underscore only in the UI, though at
  // this stage of development, it might have been too costly in terms of us
  // forgetting that the underscore should be present internally.  Or we could have
  // chosen a different representation altogether.  But that's too much work at the
  // moment. :( ~ Matt 2015-11-13
  export function typeIsReference(type) {
    return type === rootColumnId || (!/^_/.test(type) && NON_REFERENCE_TYPES.indexOf(type) < 0);
  }

  export function commonSupertype(t1, t2) {
    return t1 !== TYPE_EMPTY ? t2 !== TYPE_EMPTY && t2 !== t1 ? TYPE_ERROR : t1 : t2;
  }

  export class TypedSet {
    // public fields
    //@type: column ID or primitive, or TYPE_EMPTY if we don't know because the set is empty.
    //@set: EJSONKeyedSet<@type>

    constructor(public type : fixmeAny = TYPE_EMPTY, public set : fixmeAny = new EJSONKeyedSet()) {}

    // Note, these can make a meaningless mess if the types are mixed.  The caller
    // has to check @type afterwards.

    public add(xType, x) {
      this.type = commonSupertype(this.type, xType);
      this.set.add(x);
    }

    public addAll(tset) {
      this.type = commonSupertype(this.type, tset.type);
      for (let e of tset.set.elements()) {
        this.set.add(e);
      }
    }

    public elements() {
      return this.set.elements();
    }

    public typeName() {
      return "TypedSet";
    }

    public toJSONValue() {
      return {
        type: this.type,
        set: this.set.toJSONValue()
      };
    }

    public static fromJSONValue(json) {
      return new TypedSet(json.type, EJSONKeyedSet.fromJSONValue(json.set));
    }
  }
  EJSON.addType("TypedSet", TypedSet.fromJSONValue);

  // The next two definitions are exported for the action bar.

  export function allowedReferenceDisplayColumns(col) {
    let allowed = [];
    // XXX: Duplicating logic from columnLogicalChildrenByName?  (Avoiding this
    // would require a comprehensive emulation layer for keys as fields.)
    if (col.type !== "_token") {
      allowed.push(col._id);
    }
    for (let childColId of col.children) {
      let childCol = getColumn(childColId);
      if (!childCol.isObject) {
        allowed.push(childColId);
      }
    }
    return allowed;
  }

  export function defaultReferenceDisplayColumn(col) {
    // Current heuristic: First allowed.
    //
    // NOTE: Formulas are allowed to depend on the default reference display column
    // via toText, so reordering columns may change the spreadsheet values!  This
    // is a little surprising, but I think it's better than any of the
    // alternatives. ~ Matt 2015-11-20
    //
    // Ideas:
    // - Prefer a tuple of fields declared unique, if and when we have that
    //   information.
    // - Require singular once we have that information.
    // - Automatically detect certain field names, e.g., "name" or "title"?  A hack
    //   but maybe the right thing in this context.

    let allowed = allowedReferenceDisplayColumns(col);
    return allowed.length > 0 ? allowed[0] : null;
  }

  // Used on the server to reparse values in changeColumnSpecifiedType.
  export function parseValue(type, text) {
    if (typeIsReference(type)) {
      // Ignore erroneous families: they do not contain any objects we can match against.
      // Also ignore references that fail to convert to text.
      let matchingCells = [];
      for (let cellId of allCellIdsInColumnIgnoreErrors(type)) {
        try {
          if (text === valueToText(liteModel, type, cellId)) {
            matchingCells.push(cellId);
          }
        } catch (e) {
          // Skip
        }
      }
      if (matchingCells.length === 1) {
        return matchingCells[0];
      } else if (matchingCells.length > 1) {
        throw new Error(`The entered text matches ${matchingCells.length} '${stringifyType(type)}' objects.  ` + `Choose a reference display column for '${stringifyType(type)}' that has unique values, ` + "or define a new computed column if necessary.");  // "or enter the @n notation instead"
      } else {
        throw new Error(`The entered text does not match any existing '${stringifyType(type)}' object.`);
      }
    } else if (type === "_unit") {
      return "X";
    } else if (type === "_token") {
      // XXX: Is this OK or do we want the server to generate the token?  For
      // unprivileged users, we probably want the server to generate it, but we
      // may not reuse this code for unprivileged users anyway.
      return Random.id();
    } else     return type === "text" ? text : type === "date" ? Date.parse(text) || (() => {
      throw new Error(`Invalid date: '${text}'`);
    })() : JSON.parse(text);
  }

}
