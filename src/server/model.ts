namespace Objsheets {

  class CannedTransaction {
    // @params: EJSONKeyedMap of name to type

    constructor(public params, public body) {}
  }

  export class Model {
    public settings;
    public columnCache;
    public wasEmpty;

    // TODO: Indicate which methods are intended to be public!

    //@columns: EJSONKeyedMap<ColumnId, Column>

    constructor() {
      // Compiler produced incorrect results on SiteTotals.site on the cost sheet.
      // ~ Matt 2015-10-19
      this.settings = {
        compiler: false,
        profiling: 0
      };
      this.columnCache = {};

      // Special case: create root column if missing.
      if (this.getColumn(rootColumnId) == null) {
        this.wasEmpty = true;
        // None of the other properties should be used.
        Columns.insert({
          _id: rootColumnId,
          children: [],
          fieldName: null,
          specifiedType: "_token",  // Close enough to the truth?
          type: null,
          typecheckError: null,
          isObject: true,  // Allow children.
          objectName: null,
          referenceDisplayColumn: null,
          formula: null
        });
      }

      // If this is the first time the server process is accessing this sheet, it
      // might contain data generated by a different version of the server code.
      this.invalidateSchemaCache();
    }

    public getColumn(columnId) {
      // Treat as read-only and valid only until the model is next modified.
      // XXX: Replace by a real API.  At least the references will be easy to find.
      return fallback(this.columnCache[columnId], Columns.findOne(columnId));
    }

    public getAllColumns(columnId : any = rootColumnId) {
      var _ref;
      let col = this.getColumn(columnId);
      // A bit of auto-repair in case some columns were deleted
      let validChildren = col.children.filter((x) => this.getColumn(x) != null);
      if (validChildren.length !== col.children.length) {
        Columns.update(columnId, {
          $set: {
            children: validChildren
          }
        });
      }
      return (_ref = [[columnId, col]]).concat.apply(_ref, validChildren.map((c) => this.getAllColumns(c)));
    }

    public defineColumn(parentId, index, fieldName, specifiedType, isObject, objectName, formula, attrs) {
      // Future: validate everything
      // Future: validate no fieldName for type _token.  For _unit, there could be borderline use cases.
      // XXX: Do not allow non-object columns to have type _token?  Currently it
      // won't hurt anything, and it doesn't make sense to tighten this until we
      // finalize the flow for specifying types of newly created columns.
      let parentCol = this.getColumn(parentId);
      if (parentCol == null) {
        throw new Meteor.Error("defineColumn-no-parent", "The specified parent column does not exist.");
      }
      if (!((0 <= index && index <= parentCol.children.length))) {
        throw new Meteor.Error("defineColumn-index-out-of-range", "Index out of range");
      }
      if (!isObject && (objectName != null)) {
        throw new Meteor.Error("defineColumn-objectName-not-isObject", "A column with isObject = false cannot have an objectName.");
      }
      if (formula == null) {
        if (parentCol.formula != null) {
          throw new Meteor.Error("state-under-formula", "Cannot have a state column as child of a formula column.");
        }
        if (specifiedType == null) {
          // TODO perhaps a better flow would be to leave undefined, but check when
          //  user enters data
          throw new Meteor.Error("defineColumn-type-required", "Must specify type for a state column");
        }
      }
      if (formula != null) {
        validateFormula(formula);
      }
      this.invalidateSchemaCache();
      let thisId = Random.id();
      let col = {
        _id: thisId,
        parent: parentId,
        fieldName: fieldName,
        specifiedType: specifiedType,
        type: null,
        typecheckError: null,
        isObject: isObject,
        objectName: objectName,
        referenceDisplayColumn: null,
        formula: formula,
        children: []
      };
      for (let k in attrs || {}) {
        let v = (attrs || {})[k];
        col[k] = v;
      }
      Columns.insert(col);
      if (!parentCol.isObject) {
        this.changeColumnIsObject(parentCol._id, true);
        parentCol = this.getColumn(parentId);
        index = 1;
      }
      parentCol.children.splice(index, 0, thisId);
      // Meteor is nice for so many things, but not ORM...
      Columns.update(parentCol._id, {
        $set: {
          children: parentCol.children
        }
      });

      return thisId;
    }

    // Should be roughly equivalent to what you get by adding a field and then
    // "promoting" to an object type via the flow in changeColumnIsObject.  I'd
    // rather do this in one call to the server. ~ Matt 2015-11-12

    public insertUnkeyedStateObjectTypeWithField(parentId, index, objectName, fieldName, specifiedType, attrs) {
      let objectColId = this.defineColumn(parentId, index, null, "_token", true, objectName, null, attrs);
      let fieldColId = this.defineColumn(objectColId, 0, fieldName, specifiedType, false, null, null, attrs);
      return [objectColId, fieldColId];
    }

    private checkNameClash(columnId, childName) {
      if (columnLogicalChildrenByName(columnId, childName).length > 0) {
        var parentName = objectNameWithFallback(this.getColumn(columnId));
        throw new Meteor.Error("model-name-clash", 
          parentName ? `Object '${parentName}' already has a child named '${childName}'`
                     : `Top-level object named '${childName}' already exists.`);
      }
    }

    public changeColumnFieldName(columnId, fieldName) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      let col = this.getColumn(columnId);
      if (fieldName === col.fieldName) {
        return;
      }
      this.checkNameClash(col.parent, fieldName);
      Columns.update(columnId, {
        $set: {
          fieldName: fieldName
        }
      });
      this.invalidateColumnCache();
    }

    public changeColumnObjectName(columnId, objectName) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      let col = this.getColumn(columnId);
      if (objectName === col.objectName) {
        return;
      }
      if (!col.isObject && (objectName != null)) {
        throw new Meteor.Error("defineColumn-objectName-not-isObject", "A column with isObject = false cannot have an objectName.");
      }
      this.checkNameClash(col.parent, objectName);
      Columns.update(columnId, {
        $set: {
          objectName: objectName
        }
      });
      this.invalidateColumnCache();
    }

    public changeColumnIsObject(columnId, isObject) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      let col = this.getColumn(columnId);
      if (isObject === col.isObject) {
        return;
      }

      let updates = {
        isObject: isObject
      };
      if (isObject) {
        if (col.formula != null) {
          // Do not generate a new object name: [fieldName] is good enough.
        } else {
          // When making a state column into an object column:
          // column type becomes "_token", a new object name is generated,
          // and existing values are moved to a newly created child column
          this.invalidateSchemaCache();
          Columns.update(columnId, {
            $set: {
              specifiedType: "_token",
              isObject: true,
              objectName: nextAvailableColumnName("Object"),
              fieldName: null
            }
          });
          let childId = this.defineColumn(columnId, 0, col.fieldName, col.specifiedType, false, null, null, {});
          Cells.find({
            column: columnId
          }).forEach((family) => {
            let tokens = family.values.map((value) => Random.id());
            Cells.update(family._id, {
              $set: {
                values: tokens
              }
            });
            for (let [token, value] of zip(tokens, family.values)) {
              let key = cellIdChild(family.key, token);
              Cells.insert({
                column: childId,
                key: key,
                values: [value]
              });
            }
          });
        }
      } else {
        updates.objectName = null;
        // When making a column into a value column:
        // - If column type is "_token", values are copied from the column's only child,
        //   and that child is removed.
        // - Otherwise, column must have no children.
        if (col.type === "_token") {
          if ((col.children != null ? col.children.length : null) !== 1) {
            throw new Meteor.Error("remove-object-has-children", "Object must have a single field before converting to values.");
          }
          let childId = col.children[0];
          let childCol = this.getColumn(childId);
          if (childCol.isObject || (childCol.children != null ? childCol.children.length : null)) {
            throw new Meteor.Error("remove-object-complex-value", `Child '${fallback(fallback(childCol.objectName, childCol.fieldName), "(unnamed)")}' is not a simple value.`);
          }
          Cells.find({
            column: columnId
          }).forEach((family) => {
            let newValues = [];
            for (let value of family.values) {
              Cells.find({
                column: childId,
                key: value
              }).forEach((family) => {
                for (let subValue of family.values) {
                  newValues.push(subValue);
                }
              });
            }
            Cells.update(family._id, {
              $set: {
                values: newValues
              }
            });
          });
          updates.specifiedType = childCol.type;
          updates.fieldName = childCol.fieldName;
          updates.children = [];
          Columns.remove(childId);
          Cells.remove({
            column: childId
          });
          this.invalidateSchemaCache();
        } else {
          if (col.children != null ? col.children.length : null) {
            throw new Meteor.Error("remove-object-has-children", "Please delete all child columns first.");
          }
        }
      }
      Columns.update(columnId, {
        $set: updates
      });
      this.invalidateColumnCache();
    }

    public changeColumnSpecifiedType(columnId, specifiedType) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      let col = this.getColumn(columnId);
      if (specifiedType === col.specifiedType) {
        return;
      }
      if ((col.specifiedType === "_token") !== (specifiedType === "_token")) {
        throw new Meteor.Error("change-type-token", "Cannot change a column type to or from _token.");
      }
      let newFamilies;
      if (col.formula == null) {
        if (col.isObject) {
          throw new Meteor.Error("change-type-state-keyed-object", "Oops... we haven't implemented changing the key type of a state object column " + "since we're deprecating state keyed objects.");
        }
        // If we get here, there should be no descendant data to worry about.
        // Reparse existing data as the new type /before/ we invalidate computed
        // reference display columns.
        newFamilies = Cells.find({
          column: columnId
        }).fetch().map((family) => {
          let newValues = [];
          for (let v of family.values) {
            try {
              // XXX: It's O(m*n) to parse m references to an object column with n objects.  Add caching.
              newValues.push(parseValue(specifiedType, valueToText(liteModel, col.specifiedType, v)));
            } catch (e) {
              // Ignore
            }
          }
          // Object newly allocated by fetch(), OK to mutate
          family.values = newValues;
          return family;
        });
      }

      this.invalidateSchemaCache();
      Columns.update(columnId, {
        $set: {
          specifiedType: specifiedType
        }
      });
      if (col.formula == null) {
        // XXX If we crash here, the database will be corrupt, but there are
        // probably many other cases just as bad...
        for (let family of newFamilies) {
          // XXX _id should be stable for state families, but cleaner not to rely
          // on it (or change _id to be column+key like we were discussing).
          Cells.update(family._id, {
            $set: {
              values: family.values
            }
          });
        }
      }
    }

    public _changeColumnType(columnId, type) {
      Columns.update(columnId, {
        $set: {
          type: type
        }
      });
    }

    public _changeColumnTypecheckError(columnId, typecheckError) {
      Columns.update(columnId, {
        $set: {
          typecheckError: typecheckError
        }
      });
    }

    // Future: API to move and copy groups of columns.  This is an order of
    // magnitude more complicated.

    public changeColumnFormula(columnId, formula) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      if (formula != null) {
        validateFormula(formula);
      }

      let col = this.getColumn(columnId);
      let updates = {
        formula: formula
      };
      if ((col.formula == null) && (formula != null)) {
        for (let childColumnId of col.children) {
          if (this.getColumn(childColumnId).formula == null) {
            throw new Meteor.Error("state-under-formula", "Cannot have a state column as child of a formula column.");
          }
        }

        // Currently this is allowed to just blow away existing state cells.

        // Hack: When a state column is converted to a formula column,
        // automatically remove the specified type.  This should be OK because having
        // to specify a type for a formula column is a rare case.  If at some point
        // we distinguish whether state column types were user-specified or inferred
        // from data, then we could consider keeping a user-specified type here.
        updates.specifiedType = null;
      } else if ((col.formula != null) && (formula == null)) {
        let parentCol = this.getColumn(col.parent);
        if (parentCol.formula != null) {
          throw new Meteor.Error("state-under-formula", "Cannot have a state column as child of a formula column.");
        }
        if (col.type !== TYPE_EMPTY && col.type !== TYPE_ERROR) {
          // We'd better set a specifiedType that matches the evaluated families.
          // If col.specifiedType is already set, col.type will be the same and
          // this will be a no-op.
          updates.specifiedType = col.type;
        } else {
          // In this case, there are no nonempty evaluated families.
          // The user can easily change the type if it isn't what they want.
          updates.specifiedType = DEFAULT_STATE_FIELD_TYPE;
        }
        // Convert erroneous families to empty. :/
        Cells.update({
          column: columnId,
          error: {
            $exists: true
          }
        }, {
          $unset: {
            error: null
          },
          $set: {
            values: []
          }
        }, {
          multi: true
        });
      }

      Columns.update(columnId, {
        $set: updates
      });
      this.invalidateSchemaCache();  // type may change
    }

    public changeColumnReferenceDisplayColumn(columnId, referenceDisplayColumn) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      // Don't bother with further validation here because we have to be prepared
      // anyway for the choice of reference display column to become invalid as a
      // result of modifications to the sheet.
      // We use a different convention than Match.Optional...
      check(referenceDisplayColumn, Match.OneOf(String, null));
      Columns.update(columnId, {
        $set: {
          referenceDisplayColumn: referenceDisplayColumn
        }
      });
    }

    public reorderColumn(columnId, newIndex) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("modify-root-column", "Cannot modify the root column.");
      }
      let col = this.getColumn(columnId);
      let parentCol = this.getColumn(col.parent);
      let children = parentCol.children.filter((x) => x !== columnId);
      children.splice(newIndex, 0, columnId);
      Columns.update(col.parent, {
        $set: {
          children: children
        }
      });
      this.invalidateColumnCache();
    }

    public deleteColumn(columnId) {
      if (columnId === rootColumnId) {
        throw new Meteor.Error("delete-root-column", "Cannot delete the root column.");
      }
      let col = this.getColumn(columnId);
      if (col.children != null ? col.children.length : null) {
        throw new Meteor.Error("delete-column-has-children", "Please delete all child columns first.");
      }
      let parentCol = this.getColumn(col.parent);
      this.invalidateSchemaCache();
      Cells.remove({
        column: columnId
      });
      parentCol.children.splice(parentCol.children.indexOf(columnId), 1);
      Columns.update(parentCol._id, {
        $set: {
          children: parentCol.children
        }
      });
      Columns.remove(columnId);
    }

    public evaluateFamily1(qFamilyId) {
      let col = this.getColumn(qFamilyId.columnId);
      if (col.formula != null) {
        let s = JSON.stringify;
        if (this.settings.profiling >= 2) {
          console.log(`[evaluateFamily1(qFamilyId=${s(qFamilyId)}) formula=${s(col.formula)}]`);
        }
        let compiled = $$.formulaEngine.compiled[qFamilyId.columnId];
        if (col.typecheckError != null) {
          throw new EvaluationError(`Formula failed type checking: ${col.typecheckError}`);
        }
        let result;
        if (compiled != null) {
          result = new TypedSet(col.type, compiled($$.formulaEngine, [qFamilyId.cellId]));
        } else {
          let vars = new EJSONKeyedMap([["this", new TypedSet(col.parent, new EJSONKeyedSet([qFamilyId.cellId]))]]);
          result = evaluateFormula(this, vars, col.formula);
        }
        if (0) {  //compiled?
          let result1 = new TypedSet(col.type, compiled($$.formulaEngine, vars.get("this").set.elements()));
          if (!EJSON.equals(result, result1)) {
            console.log(`Wrong output from compiler;\nformula=${s(col.formula)}]`);
            console.log(`> interpreter result = ${s(result)}`);
            console.log(`> compiled result    = ${s(result1)}`);
            console.log("-----------------------------");
          }
        }
        if (this.settings.profiling >= 2) {
          console.log("[/evaluateFamily1]");
        }
        return result;
      } else {
        // State column;
        // Must be empty, otherwise we wouldn't have gotten here.
        // XXX: Be consistent about which state families exist in the DB.
        return new TypedSet(col.type);
      }
    }

    public evaluateFamily(qFamilyId) {
      let keyFields = {
        column: qFamilyId.columnId,
        key: qFamilyId.cellId
      };
      let ce = Cells.findOne(keyFields);
      if (ce == null) {
        Cells.insert(keyFields);
        try {
          let content = this.evaluateFamily1(qFamilyId);
          Cells.update(keyFields, {
            $set: {
              values: content.elements()
            }
          });
        } catch (e) {
          if (e instanceof EvaluationError) {
            Cells.update(keyFields, {
              $set: {
                error: e.message
              }
            });
          } else {
            throw e;
          }
        }
        ce = Cells.findOne(keyFields);
      }

      if (ce.values != null) {
        return new TypedSet(this.getColumn(qFamilyId.columnId).type, new EJSONKeyedSet(ce.values));
      } else {
        return null;
      }
    }

    // This method serves two purposes:
    // - Determine the type that the column should be assumed to have for the
    //   purposes of other formulas.
    // - Determine whether the formula passes type checking before we try to
    //   evaluate it.
    // These don't have to be done at the same time, but for now that's convenient.

    public typecheckColumn(columnId) {
      let col = this.getColumn(columnId);
      // Reference to a deleted column?
      if (col == null) {
        return TYPE_ERROR;
      }
      let type = col.type;
      if (type == null) {
        // Formula columns of unspecified type are set to TYPE_ERROR at the
        // beginning for cycle detection, analogous to how family evaluation works.
        type = fallback(col.specifiedType, TYPE_ERROR);
        this._changeColumnType(columnId, type);
        if (col.formula != null) {
          try {
            let vars = new EJSONKeyedMap([["this", col.parent]]);
            type = typecheckFormula(this, vars, col.formula);
            if (type == null) {
              // This kind of bug would otherwise cause the client to be
              // permanently not ready, which is tedious to debug.
              throw new Error("typecheckFormula returned null/undefined");
            }
            if (col.specifiedType != null) {
              valAssert(commonSupertype(col.specifiedType, type) === col.specifiedType, `Column '${stringifyColumnRef([columnId, true])}' ` + `formula returns '${stringifyType(type)}', ` + `which is not convertible to the specified type '${col.specifiedType}'`);
            } else {
              this._changeColumnType(columnId, type);
            }
            if (this.settings.compiler && ($$.formulaEngine.compiled[columnId] == null)) {
              let fc = new FormulaCompiler($$.formulaEngine);
              if (fc.isCompilationSupported(col.formula)) {
                $$.formulaEngine.compiled[columnId] = fc.compileAsFunc(col.formula);
              }
            }
          } catch (e) {
            if (!(e instanceof FormulaValidationError)) {
              throw e;
            }
            // If type was unspecified, it is left as TYPE_ERROR, i.e., unknown
            // for the purposes of other formulas.
            this._changeColumnTypecheckError(columnId, e.message);
          }
        }
      }

      console.assert(type != null);
      return type;
    }

    public typecheckAll() {
      if (this.settings.profiling >= 1) {
        console.log("<typecheckAll>");
      }
      for (let [columnId, _] of this.getAllColumns()) {
        this.typecheckColumn(columnId);
      }
      if (this.settings.profiling >= 1) {
        console.log("</typecheckAll>");
      }
    }

    public evaluateAll() {
      // We're now assuming that everything that can make the computed data invalid
      // during one run of the server calls invalidateDataCache, so we don't do it
      // here.  Extra evaluateAll calls will find everything already done and make
      // no changes.
      if (this.settings.profiling >= 1) {
        console.log("<evaluateAll>");
      }
      this.typecheckAll();
      this.populateColumnCache();

      let evaluateSubtree = (qCellId) => {
        let col = this.getColumn(qCellId.columnId);
        for (let childColId of col.children) {
          let tset = this.evaluateFamily({
            columnId: childColId,
            cellId: qCellId.cellId
          });
          if (tset != null) {
            for (let value of tset.elements()) {
              let childQCellId = {
                columnId: childColId,
                cellId: cellIdChild(qCellId.cellId, value)
              };
              evaluateSubtree(childQCellId);
            }
          }
        }
      };

      // Future: Only evaluate what users are viewing.
      evaluateSubtree({
        columnId: rootColumnId,
        cellId: rootCellId
      });
      if (this.settings.profiling >= 1) {
        console.log("</evaluateAll>");
      }
    }

    //# Removes all column definitions and data!

    public drop() {
      Columns.remove({
        _id: {
          $ne: rootColumnId
        }
      });
      Columns.update(rootColumnId, {
        $set: {
          children: []
        }
      });
      Cells.remove({});
    }

    public populateColumnCache() {
      for (let c of Columns.find().fetch()) {
        this.columnCache[c._id] = c;
      }
    }

    public invalidateColumnCache() {
      this.columnCache = {};
    }

    public invalidateSchemaCache() {
      if (this.settings.profiling >= 1) {
        console.log("--- invalidateSchemaCache ---");
      }
      this.invalidateColumnCache();
      this.invalidateDataCache();
      if ($$.formulaEngine != null) {
        $$.formulaEngine.invalidateSchemaCache();
      }
      for (let [columnId, col] of this.getAllColumns()) {
        if (!(columnId !== rootColumnId)) {
          continue;
        }
        this._changeColumnType(columnId, null);
        this._changeColumnTypecheckError(columnId, null);
      }
    }

    public invalidateDataCache() {
      if (this.settings.profiling >= 1) {
        console.log("--- invalidateDataCache ---");
      }
      for (let [columnId, col] of this.getAllColumns()) {
        if (columnId !== rootColumnId) {
          if (col.formula != null) {
            Cells.remove({
              column: columnId
            });
          }
        }
      }
    }

    // Procedure object:
    // {
    //   name: string
    //   params: list of {name (str), type (str as usual), singular (bool)}
    //   body: statements list
    // }

    public defineProcedure(proc) {
      proc._id = Random.id();
      validateProcedure(proc);
      Procedures.insert(proc);
      return proc._id;
    }

    // Overwrites (and optionally renames) the existing procedure with procId.

    public redefineProcedure(procId, proc) {
      delete proc._id;  // ignored if passed
      validateProcedure(proc);
      // It's OK to pass a replacement document without an id:
      // https://docs.mongodb.org/manual/reference/method/db.collection.update/#update-parameter
      // No effect if no procedure with the ID exists.  OK?
      Procedures.update(procId, proc);
    }

    public deleteProcedure(procId) {
      // No effect if no procedure with the ID exists.  OK?
      Procedures.remove(procId);
    }

    public executeCannedTransaction(name, argsObj) {
      let proc = Procedures.findOne({
        name: name
      });
      if (proc == null) {
        throw new Meteor.Error("no-such-procedure", `No such procedure '${name}'.`);
      }
      // Typecheck the procedure.  TODO: Cache this like for column formulas.
      try {
        typecheckProcedure(this, proc);
      } catch (e) {
        if (!(e instanceof FormulaValidationError)) {
          throw e;
        }
        console.log(e.stack);
        throw new Meteor.Error("procedure-ill-typed", `Procedure '${name}' is ill-typed with respect to the current schema and cannot be executed.`);
      }
      // Future: Validate argument types!
      // Future: Add built-in parameters (clientUser, currentTime) here.
      let args = new EJSONKeyedMap(proc.params.map((param) => [param.name, new TypedSet(param.type, set(argsObj[param.name]))]));
      try {
        $$.runTransaction(() => {
          executeProcedure(this, proc, args);
          this.evaluateAll();
        });
      } catch (e) {
        if (e instanceof EvaluationError) {
          console.log("Transaction failed:", name, argsObj, e.stack);
          // Future: How much information to send to unprivileged clients?
          throw new Meteor.Error("transaction-failed", "Transaction failed.");
        } else {
          throw e;
        }
      }
    }

    public repair() {
      // We can add repair steps for crashes and bugs in old versions of the code here.
      this.invalidateSchemaCache();

      // Remove orphaned columns and state families.

      let liveColumnIds = new EJSONKeyedSet();
      let scanColumnSubtree = (columnId) => {
        liveColumnIds.add(columnId);
        let col = this.getColumn(columnId);
        for (let childColId of col.children) {
          scanColumnSubtree(childColId);
        }
      };
      scanColumnSubtree(rootColumnId);
      for (let col of Columns.find().fetch()) {
        if (!liveColumnIds.has(col._id)) {
          Columns.remove(col);
        }
      }

      let liveFamilies = new EJSONKeyedSet();  // {column, key}
      // Traversal code adapted from evaluateAll.
      let scanCellSubtree = (qCellId) => {
        col = this.getColumn(qCellId.columnId);
        for (let childColId of col.children) {
          let keyFields = {
            column: childColId,
            key: qCellId.cellId
          };
          liveFamilies.add(keyFields);
          let ce = Cells.findOne(keyFields);
          if ((ce != null ? ce.values : null) != null) {
            for (let value of ce.values) {
              let childQCellId = {
                columnId: childColId,
                cellId: cellIdChild(qCellId.cellId, value)
              };
              scanCellSubtree(childQCellId);
            }
          }
        }
      };
      scanCellSubtree({
        columnId: rootColumnId,
        cellId: rootCellId
      });
      for (let ce of Cells.find().fetch()) {
        if (!liveFamilies.has({
          column: ce.column,
          key: ce.key
        })) {
          Cells.remove(ce);
        }
      }

      for (let col of Columns.find().fetch()) {
        if (col.formula != null) {
          // A mitigation for the common problem of formula operations being
          // removed.  There are obviously many other ways a bad database can break
          // us.
          try {
            validateFormula(col.formula);
          } catch (e) {
            if (!(e instanceof Meteor.Error && e.error === "invalid-formula")) {
              throw e;
            }
            console.log(`Column '${stringifyColumnRef([col._id, true])}' contains invalid formula ` + `${JSON.stringify(col.formula)}: ${e.message}.  Resetting.`);
            col.formula = DUMMY_FORMULA;
            col.specifiedType = null;
            Columns.update(col._id, col);
          }
        }
      }
    }
  }

  // Used by procedures and the UI.
  // Keeping this parallel with the other ways the UI modifies data, which don't go
  // through the model or call invalidateDataCache.  XXX: Fix this (lack of) API.
  export function recursiveDeleteStateCellNoInvalidate(columnId, cellId) {
    var ce;
    let col = getColumn(columnId);
    for (let childColId of col.children) {
      let childCol = getColumn(childColId);
      if (childCol.formula == null) {
        // Empty families are only inserted during evaluateAll, so they may not yet
        // exist for objects created in the same transaction.
        if ((ce = Cells.findOne({
          column: childColId,
          key: cellId
        })) != null) {
          for (let val of ce.values) {
            // The Cells.update in here is subsumed by the Cells.remove below.  Oh well.
            recursiveDeleteStateCellNoInvalidate(childColId, cellIdChild(cellId, val));
          }
          Cells.remove({
            column: childColId,
            key: cellId
          });
        }
      }
    }
    Cells.update({
      column: columnId,
      key: cellIdParent(cellId)
    }, {
      $pull: {
        values: cellIdLastStep(cellId)
      }
    });
  }

  Meteor.startup(() => {
    var tspace;
    Tablespace.onCreate(function() {
      this["do"](function() {
        console.log(`creating model of [${this.id}]`);
        this.model = new Model;
        this.formulaEngine = new FormulaEngine;
        let appName = /(?:^|\.)([^.]+)$/.exec(this.id) != null ? /(?:^|\.)([^.]+)$/.exec(this.id)[1] : null;
        if (this.model.wasEmpty) {
          //if appName == 'ptc' then loadPTCData(@model)
          //else
          loadDumpIfExists(this.model, appName);
          // TO MAKE A DUMP:
          // ./private/scripts/mkdump APPNAME
        }
        this.model.repair();
        this.model.evaluateAll();
      });
    });

    if (Meteor.isServer) {  // this condition is here to allow standalone mode
      Tablespace["default"] = tspace = Tablespace.get("ptc");  // mostly for use in the shell
      //tspace.run()  # Slows down server startup.
    }

  });

  Meteor.methods({
    // The model methods do not automatically evaluate so that we can do bulk
    // changes from the server side, but for now we always evaluate after each
    // change from the client.  It would be a little harder for the client itself
    // to request this via another method (it would require a callback).
    // Future: validation!
    open: (cc) => {
      cc.run();
    },
    defineColumn: (cc, parentId, index, fieldName, specifiedType, isObject, objectName, formula, viewId) => {
      cc.run(function() {
        //attrs = if viewId? then {view: viewId} else {}
        let id = this.model.defineColumn(parentId, index, fieldName, specifiedType, isObject, objectName, formula);
        if (viewId != null) {
          new View(viewId).addColumn(id, true);  // FIXME: honor index
        }
        this.model.evaluateAll();
      });
    },
    insertUnkeyedStateObjectTypeWithField: (cc, parentId, index, objectName, fieldName, specifiedType, viewId) => {
      cc.run(function() {
        //attrs = if viewId? then {view: viewId} else {}
        let [objectColId, fieldColId] = this.model.insertUnkeyedStateObjectTypeWithField(parentId, index, objectName, fieldName, specifiedType);
        if (viewId != null) {
          let view = new View(viewId);
          view.addColumn(objectColId, true);  // FIXME: honor index
          view.addColumn(fieldColId, true);  // FIXME: honor index
        }
        this.model.evaluateAll();
      });
    },
    changeColumnFieldName: (cc, columnId, fieldName) => {
      cc.run(function() {
        this.model.changeColumnFieldName(columnId, fieldName);
      });
    },
    changeColumnIsObject: (cc, columnId, isObject) => {
      cc.run(function() {
        this.model.changeColumnIsObject(columnId, isObject);
        // For the case where a token object is converted to or from a field.
        this.model.evaluateAll();
      });
    },
    changeColumnObjectName: (cc, columnId, objectName) => {
      cc.run(function() {
        this.model.changeColumnObjectName(columnId, objectName);
      });
    },
    changeColumnSpecifiedType: (cc, columnId, specifiedType) => {
      cc.run(function() {
        this.model.changeColumnSpecifiedType(columnId, specifiedType);
        this.model.evaluateAll();
      });
    },
    changeColumnFormula: (cc, columnId, formula) => {
      cc.run(function() {
        this.model.changeColumnFormula(columnId, formula);
        this.model.evaluateAll();
      });
    },
    changeColumnReferenceDisplayColumn: (cc, columnId, referenceDisplayColumn) => {
      cc.run(function() {
        this.model.changeColumnReferenceDisplayColumn(columnId, referenceDisplayColumn);
      });
    },
    reorderColumn: (cc, columnId, newIndex) => {
      cc.run(function() {
        this.model.reorderColumn(columnId, newIndex);
      });
    },
    deleteColumn: (cc, columnId) => {
      cc.run(function() {
        this.model.deleteColumn(columnId);
        View.removeColumnFromAll(columnId);
        this.model.evaluateAll();
      });
    },
    recursiveDeleteStateCellNoInvalidate: (cc, columnId, cellId) => {
      cc.run(() => {
        recursiveDeleteStateCellNoInvalidate(columnId, cellId);
      });
    },
    notify: (cc) => {
      cc.run(function() {
        this.model.invalidateDataCache();
        this.model.evaluateAll();
      });
    },
    executeCannedTransaction: (cc, name, argsObj) => {
      cc.run(function() {
        this.model.executeCannedTransaction(name, argsObj);
      });
    }
  });

}
