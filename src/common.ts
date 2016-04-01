// check-implicit-any magic comment: noImplicitAny

// Relational Spreadsheets definitions needed by both client and server that
// don't fall into a more specific file such as formulas.coffee.


namespace Objsheets {

  // In the future, we can consider "branding" these like Path in the TypeScript
  // compiler.
  export type ColumnId = string;
  export type OSType = string;

  export var rootColumnId: ColumnId = "_root";

  // Multisets unsupported for now: twindex removed.

  type Token = string;
  export type OSValue = Token | boolean | number | string | Date | CellId1;
  // FIXME: I wanted to name this CellId.  Resolve name clash with CellId in
  // data.ts. ~ Matt 2016-03-14
  // Direct recursion (type CellId1 = OSValue[]) is not allowed.  But because
  // subtyping is structural, this seems to be equivalent!
  export interface CellId1 extends Array<OSValue> {}

  export var rootCellId: CellId1 = [];

  export function cellIdParent(cellId: CellId1): CellId1;
  export function cellIdParent(cellId: CellIdWithSpares): CellIdWithSpares;
  export function cellIdParent<T>(cellId: T[]): T[] {
    return cellId.slice(0, -1);
  }
  export function cellIdChild(cellId: CellId1, value: OSValue): CellId1;
  export function cellIdChild(cellId: CellIdWithSpares, value: OSValueWithSpares): CellIdWithSpares;
  export function cellIdChild<T>(cellId: T[], value: T): T[] {
    return cellId.concat([value]);
  }
  export function cellIdLastStep(cellId: CellId1): OSValue;
  export function cellIdLastStep(cellId: CellIdWithSpares): OSValueWithSpares;
  export function cellIdLastStep<T>(cellId: T[]): T {
    return cellId[cellId.length - 1];
  }

  // TODO: Rename one of the cellId fields once the code is typed well enough
  // that we can do it reliably.
  export interface QCellId extends EJSONableDict {
    columnId: ColumnId;
    cellId: CellId1;
  }
  export interface QFamilyId extends EJSONableDict {
    columnId: ColumnId;
    cellId: CellId1;
  }

  // Note, these can exist for keyed object types, but for now, we only support
  // computed keyed object types (and no updatable views), so spare keyed
  // objects will never be editable.
  export class SpareValue {
    constructor(public index: number) {}

    public typeName(): string {
      return "SpareValue";
    }

    public toJSONValue(): JSONable {
      return this.index;
    }

    public static fromJSONValue(json: any): SpareValue {
      return new SpareValue(json);
    }
  }
  EJSON.addType("SpareValue", SpareValue.fromJSONValue);

  // OSValueWithSpares intentionally does not include CellIdWithSpares.  Spare
  // values may appear only in the main hierarchy of a CellIdWithSpares; any
  // embedded object references must be real.
  export type OSValueWithSpares = OSValue | SpareValue;

  // Unenforced constraint: values (keys) are real up to a point and spare after
  // that.
  export interface CellIdWithSpares extends Array<OSValueWithSpares> {}
  export interface QCellIdWithObjectSpares extends EJSONableDict {
    columnId: ColumnId;
    cellId: CellIdWithSpares;
  }
  export interface QCellIdWithSpares extends EJSONableDict {
    columnId: ColumnIdWithSpares;
    cellId: CellIdWithSpares;
  }
  export interface QFamilyIdWithSpares extends EJSONableDict {
    columnId: ColumnIdWithSpares;
    cellId: CellIdWithSpares;
  }

  // TypeScript is trusting us to narrow the type.
  export function cellIdIsReal(cellId: CellIdWithSpares): cellId is CellId1 {
    return cellId.length == 0 || !(cellIdLastStep(cellId) instanceof SpareValue);
  }
  // cellIdIsReal(qCellId.cellId) does not narrow the type of qCellId.cellId, so
  // define this as well.
  export function qCellIdIsReal(qCellId: QCellIdWithSpares): qCellId is QCellId {
    // Hmm, it shouldn't actually be possible to have real cells in a spare column.
    return columnIdIsReal(qCellId.columnId) && cellIdIsReal(qCellId.cellId);
  }
  export function qFamilyIdIsReal(qFamilyId: QFamilyIdWithSpares): qFamilyId is QFamilyId {
    // But it is possible to have families in a spare column with real parent cells.
    return columnIdIsReal(qFamilyId.columnId) && cellIdIsReal(qFamilyId.cellId);
  }

  export function cellIdNearestRealAncestor(cellId: CellIdWithSpares): CellId1 {
    let i = cellId.length;
    while (i > 0 && cellId[i-1] instanceof SpareValue)
      i--;
    return <CellId1>cellId.slice(0, i);
  }
  export function cellIdIsAncestor(high: CellIdWithSpares, low: CellIdWithSpares): boolean {
    // Note: if low.length < high.length, the second argument will be short and
    // EJSON.equals will return false.
    return EJSON.equals(high, low.slice(0, high.length));
  }

  // N.B. Meteor.makeErrorType is the way to make a subclass of Error so that both
  // instanceof and stack traces work.

  // Careful: with "class EvaluationError", the original class gets assigned to a
  // file-scope variable that shadows the exported wrapped class seen by the rest
  // of the application, and instanceof breaks.
  class EvaluationError_ {
    constructor(public message: string) {}
  }
  export var EvaluationError = Meteor.makeErrorType("EvaluationError", EvaluationError_);

  // Used also for typechecking.
  class FormulaValidationError_ {
    constructor(public message: string) {}
  }
  export var FormulaValidationError = Meteor.makeErrorType("FormulaValidationError", FormulaValidationError_);

  class SyntaxError_ {
    // details: Jison "hash"?
    // (https://github.com/zaach/jison/blob/5e13d8563c306c66cc00b9fe22ff6da74617e792/lib/jison.js#L1046)
    constructor(public message: string, public details: fixmeAny) {}
  }
  export var SyntaxError = Meteor.makeErrorType("SyntaxError", SyntaxError_);

  class SemanticError_ {
    constructor(public message: string) {}
  }
  export var SemanticError = Meteor.makeErrorType("SemanticError", SemanticError_);

  // Model data structures and parameters the client needs to be aware of:
  // (I tried using EJSON custom classes but it was too much of a pain to store in
  // the DB.  If I find a good solution, we could go back to using EJSON custom
  // classes. ~ Matt)

  export interface ColumnWithSpares {
    _id: ColumnIdWithSpares;
    parent: ColumnIdWithSpares;
    children: ColumnId[];
    fieldName: string;  // nullable
    // type specified by user (non-null for state columns)
    specifiedType: OSType;
    // checked type (always set during evaluation)
    type: OSType;
    // formula type checking error message or null if none
    typecheckError: string;
    isObject: boolean;
    objectName: string;  // nullable
    // some JSON data structure, or null for a state column
    formula: fixmeAny;
    referenceDisplayColumn: ColumnId;
  }

  export interface Column extends ColumnWithSpares {
    _id: ColumnId;
    parent: ColumnId;
  }

  export function getColumn(id: ColumnId): Column {
    // Fail fast if we get a spare column somewhere we didn't expect it.
    // Obviously, Safe TypeScript would be much better at this if it were
    // maintained. :( ~ Matt 2016-03-18
    check(id, String);
    return Columns.findOne(id);
  }

  // Objects we can use in place of a real column ID for spare columns (client
  // only, but some code that is used on both sides needs to be able to check
  // for these).  When a spare column is edited in the UI, we have to actually
  // create it before performing the edit.

  export class SpareObjectColumnId {
    constructor() {}

    // Currently hard-wired to the root, otherwise getColumnWithSpares would
    // have to be more careful about whether to claim it's state or computed.
    get parentColumnId(): ColumnId {
      return rootColumnId;
    }

    public typeName(): string {
      return "SpareObjectColumnId";
    }

    public toJSONValue(): JSONable {
      return {};
    }

    public static fromJSONValue(json: any): SpareObjectColumnId {
      return new SpareObjectColumnId();
    }
  }
  EJSON.addType("SpareObjectColumnId", SpareObjectColumnId.fromJSONValue);

  export class SpareValueColumnId {
    constructor(
      public parentColumnId : ColumnId | SpareObjectColumnId,
      public index : number = 0) {}

    public typeName(): string {
      return "SpareValueColumnId";
    }

    // TODO: Cut down on this boilerplate by defining a mix-in that takes a list
    // of property names?  But then TypeScript won't enforce that the properties
    // are EJSONable.
    public toJSONValue(): JSONable {
      return {
        parentColumnId: EJSON.toJSONValue(this.parentColumnId),
        index: this.index
      };
    }

    public static fromJSONValue(json: any): SpareValueColumnId {
      return new SpareValueColumnId(EJSON.fromJSONValue(json.parentColumnId), json.index);
    }
  }
  EJSON.addType("SpareValueColumnId", SpareValueColumnId.fromJSONValue);

  export type ColumnIdWithSpares = ColumnId | SpareObjectColumnId | SpareValueColumnId;

  export function getColumnWithSpares(columnId : ColumnIdWithSpares): ColumnWithSpares {
    // These should be all the fields we use.  We can type this properly with
    // TypeScript later. :(

    // This data should match insertBlankColumn, except we don't assign names
    // unless/until a spare column is actually created.
    if (columnId instanceof SpareObjectColumnId)
      return {
        _id: columnId,
        parent: columnId.parentColumnId,
        specifiedType: "_token",  // for action bar type menu
        type: "_token",
        typecheckError: null,  // for "change #changeColumn-backend" handler
        fieldName: null,
        isObject: true,
        objectName: '(new object column)',
        formula: null,  // state, because the parent is always the root
        children: [],  // for allowedReferenceDisplayColumns
        referenceDisplayColumn: null,
      };
    else if (columnId instanceof SpareValueColumnId)
      return {
        _id: columnId,
        parent: columnId.parentColumnId,
        specifiedType: DEFAULT_STATE_FIELD_TYPE,  // for action bar type menu
        type: DEFAULT_STATE_FIELD_TYPE,
        typecheckError: null,  // for "change #changeColumn-backend" handler
        fieldName: '(new value column)',
        isObject: false,
        objectName: null,
        formula: null,
        children: [],  // for allowedReferenceDisplayColumns
        referenceDisplayColumn: null,
      };
    else
      return getColumn(columnId);
  }

  export function columnIdIsReal(columnId : ColumnIdWithSpares): columnId is ColumnId {
    return typeof columnId === "string";
  }

  export function columnIsState(col: ColumnWithSpares) {
    return col._id !== rootColumnId && (col.formula == null);
  }

  export function objectNameWithFallback(col: ColumnWithSpares): string {
    return fallback(col.objectName, (col.fieldName != null ? `[${col.fieldName}]` : null));
  }

  export function columnSiblingIndex(columnId: ColumnId): number {
    let col = getColumn(columnId);
    let parentCol = getColumn(col.parent);
    return parentCol.children.indexOf(col._id);
  }

  export function columnDepth(columnId: ColumnId): number {
    return columnId === rootColumnId ? 0 : 1 + columnDepth(getColumn(columnId).parent);
  }

  export function nextAvailableColumnName(prefix: string): string {
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

  type LogicalChildInfo = [ColumnRef, /* "up" or "down" */ string];

  // This implements the user-facing conceptual model in which a key is a child of the object.
  // Precondition: getColumn(id).isObject == true
  // Having direction here is a little awkward but lets us reuse this in resolveNavigation.
  export function columnLogicalChildrenByName(id: ColumnId, wantName: string): LogicalChildInfo[] {
    let col = getColumn(id);
    let ret: LogicalChildInfo[] = [];
    function visit(name: string, descriptor: LogicalChildInfo) {
      if (name === wantName) {
        ret.push(descriptor);
      }
    }
    visit(col.fieldName, [[id, true], "up"]);
    for (let physChildCol of Columns.find({
      parent: id
    }).fetch()) {
      if (physChildCol.isObject) {
        visit(objectNameWithFallback(physChildCol), [[physChildCol._id, false], "down"]);
      } else {
        visit(physChildCol.fieldName, [[physChildCol._id, true], "down"]);
      }
    }
    return ret;
  }

  export function stringifyType(type: OSType): string {
    return typeIsReference(type) ? stringifyColumnRef([type, false]) : type;
  }

  export function parseTypeStr(s: string): OSType {
    // This is an abuse of typeIsReference, since s is a UI-level (not internal)
    // type string, but it will work to check whether s is recognized as the name
    // of a non-reference type.
    return typeIsReference(s) ? parseObjectTypeRef(s) : s;
  }

  export function parseObjectTypeRef(s: string): OSType {
    let colId2 = parseColumnRef(s);
    if (colId2[1]) {
      throw new SemanticError(`'${s}' refers to a value column, not an object type.`);
    }
    return colId2[0];
  }

  // Compare to resolveNavigation.
  type ColumnRef = [ColumnId, /* isValues */ boolean];
  export function parseColumnRef(s: string): ColumnRef {
    if (!s) {
      // What we currently want for user-facing usage.  load-sample-data has to
      // override this behavior. :/
      throw new SemanticError("We currently do not support references to the root column.");
    }
    let colId2 : ColumnRef = [rootColumnId, false];
    for (let n of s.split(":")) {
      if (colId2[1]) {
        throw new SemanticError(`Looking up child '${n}' of a value column.`);
      }
      let interpretations = columnLogicalChildrenByName(colId2[0], n);
      if (interpretations.length !== 1) {
        throw new SemanticError(`${interpretations.length} interpretations for ` + `${stringifyColumnRef(colId2)}:${n}, wanted one.`);
      }
      colId2 = interpretations[0][0];
    }
    return colId2;
  }

  // Compare to stringifyNavigation.
  // Eek, I guess we'll allow spare columns here for the benefit of the action
  // bar. ~ Matt 2016-03-10
  type ColumnRefWithSpares = [ColumnIdWithSpares, /* isValues */ boolean];
  export function stringifyColumnRef([columnId, isValues]: ColumnRefWithSpares): string {
    if (columnId === rootColumnId) {
      // XXX Consider reenabling the error after more testing. ~ Matt 2015-11-25
      //throw new SemanticError('We currently do not support references to the root column.')
      return "$";
    }
    let names: string[] = [];
    while (columnId !== rootColumnId) {
      let col = getColumnWithSpares(columnId);
      if (col == null) {
        return "(deleted)";
      }
      let name = isValues ? col.fieldName : objectNameWithFallback(col);
      let logicalParent = isValues && col.isObject ? columnId : col.parent;
      if (name != null) {
        if (columnIdIsReal(columnId) &&
            /* A little reasoning that goes beyond TypeScript: if columnId is
               real, then so is its logical parent. */
            columnLogicalChildrenByName(<ColumnId>logicalParent, name).length !== 1) {
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
  export function findCommonAncestorPaths(columnId1: ColumnId, columnId2: ColumnId):
      [ColumnId[], ColumnId[]] {
    let ancestors1: ColumnId[] = [];
    let cid = columnId1;
    while (true) {
      ancestors1.push(cid);
      if (cid === rootColumnId) {
        break;
      }
      cid = getColumn(cid).parent;
    }
    let ancestors2: ColumnId[] = [];
    cid = columnId2;
    let idx: number;
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
  export var TYPE_EMPTY: OSType = "empty";

  export var TYPE_ERROR: OSType = "error";

  export var MAIN_PRIMITIVE_TYPES: OSType[] = ["text", "number", "bool", "date"];
  export var DEFAULT_STATE_FIELD_TYPE: OSType = "text";

  // Other special types:
  // _root: reference, should never be user-visible (no concrete syntax to get at it)
  // _unit: primitive, deprecated but still used in ptc
  // _token: special primitive, should never be user-visible

  let NON_REFERENCE_TYPES: OSType[] = [TYPE_EMPTY, TYPE_ERROR].concat(MAIN_PRIMITIVE_TYPES);

  // It's messy to have some primitive types that begin with underscore and others
  // that don't.  We could have hidden the underscore only in the UI, though at
  // this stage of development, it might have been too costly in terms of us
  // forgetting that the underscore should be present internally.  Or we could have
  // chosen a different representation altogether.  But that's too much work at the
  // moment. :( ~ Matt 2015-11-13
  export function typeIsReference(type: OSType): boolean {
    return type === rootColumnId || (!/^_/.test(type) && NON_REFERENCE_TYPES.indexOf(type) < 0);
  }

  export function commonSupertype(t1: OSType, t2: OSType): OSType {
    return t1 !== TYPE_EMPTY ? t2 !== TYPE_EMPTY && t2 !== t1 ? TYPE_ERROR : t1 : t2;
  }

  export class TypedSet {

    constructor(public type: OSType = TYPE_EMPTY,
      public set: EJSONKeyedSet<OSValue> = new EJSONKeyedSet<OSValue>()) {}

    // Note, these can make a meaningless mess if the types are mixed.  The caller
    // has to check @type afterwards.

    public add(xType: OSType, x: OSValue): void {
      this.type = commonSupertype(this.type, xType);
      this.set.add(x);
    }

    public addAll(tset: TypedSet): void {
      this.type = commonSupertype(this.type, tset.type);
      for (let e of tset.set.elements()) {
        this.set.add(e);
      }
    }

    public elements(): OSValue[] {
      return this.set.elements();
    }

    public typeName(): string {
      return "TypedSet";
    }

    public toJSONValue(): JSONable {
      return {
        type: this.type,
        set: this.set.toJSONValue()
      };
    }

    public static fromJSONValue(json: any): TypedSet {
      return new TypedSet(json.type, EJSONKeyedSet.fromJSONValue(json.set));
    }
  }
  EJSON.addType("TypedSet", TypedSet.fromJSONValue);

  // The next two definitions are exported for the action bar.

  export function allowedReferenceDisplayColumns(col: Column): ColumnId[] {
    let allowed: ColumnId[] = [];
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

  export function defaultReferenceDisplayColumn(col: Column): ColumnId {
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
  export function parseValue(type: OSType, text: string): OSValue {
    if (typeIsReference(type)) {
      // Ignore erroneous families: they do not contain any objects we can match against.
      // Also ignore references that fail to convert to text.
      let matchingCells: CellId1[] = [];
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
