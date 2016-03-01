namespace Objsheets {

  let openCallbacks = [];
  export var RelsheetsClient = {
    open: (sheet, proceduresAppName : fixmeAny = null) => {
      Tablespace.defaultTablespace = Tablespace.get(sheet);
      $$.call("open", () => {
        if (proceduresAppName != null) {
          $$.call("compileProcedures", proceduresAppName);
        }
        $$.subscribeAll();
      });
      for (let callback of openCallbacks) {
        callback();
      }
    },
    call: (transaction, argsObj, callback?) => {
      $$.call("executeCannedTransaction", transaction, glue(argsObj), standardServerCallbackThen(callback));
    },
    onOpen: (callback) => {
      openCallbacks.push(callback);
    },
    readObj: function(t, rootCellId : fixmeAny = [], expandRefs : fixmeAny = false, keyField?, visited?) {
      var v;
      let obj = {
        qCellId: {
          columnId: t.root,
          cellId: rootCellId
        }
      };
      if (visited == null) {
        visited = new EJSONKeyedMap;
      }
      if ((v = visited.get(obj.qCellId))) {
        return v;
      }
      visited.set(obj.qCellId, obj);

      if (keyField != null) {
        obj[keyField] = cellIdLastStep(rootCellId);
      }
      for (let x of t.subtrees) {
        let c = Columns.findOne(x.root);
        if (c != null) {
          let vals = new FamilyId({
            cellId: rootCellId,
            columnId: x.root
          }).values();
          if (c.isObject) {
            let fam = vals.map((v) => this.readObj(x, cellIdChild(rootCellId, v), expandRefs, c.fieldName, visited));
            fam.qFamilyId = {
              columnId: x.root,
              cellId: rootCellId
            };
            // We could use objectNameWithFallback, but this gives easier syntax for readers.
            let objectName = fallback(c.objectName, c.fieldName);
            obj[objectName] = fam;
          } else if (c.fieldName != null) {
            // TODO: Sending the full content of all referenced objects to the client
            // is a security problem.  Remove this feature and update all affected
            // applications.  (Doesn't really matter until we have authentication.)
            if (expandRefs && (c.type != null) && typeIsReference(c.type)) {
              let ot = View.drillDown(c.type);
              vals = vals.map((v) => this.readObj(ot, v, expandRefs, Columns.findOne(ot.root) != null ? Columns.findOne(ot.root).fieldName : null, visited));
            }
            obj[c.fieldName] = vals;
          }
        }
      }

      return obj;
    },
    // Future: Deprecate this in favor of something like readSubtree?
    read: function(viewId?) {
      let layout = viewId != null ? ((new View(viewId).def()) != null ? (new View(viewId).def()).layout : null) || new Tree(rootColumnId) : View.rootLayout();
      return this.readObj(layout, [], true);
    },
    readSubtree: function(columnStr, rootCellId) {
      try {
        let columnTree = View.drillDown(parseObjectTypeRef(columnStr));
      } catch (e) {
        // Apparently the above can be attempted before the client has received the
        // entire Columns publication.  XXX: Avoid catching real errors.
        return {};
      }
      // Alternatively, we could take viewId and depth parameters and do the
      // following, which will let the developer send only a subset of the
      // descendants of the starting column to the client (once we restrict
      // publishing), but we generally expect the developer to create a dedicated
      // schema subtree for each web application view anyway.
      //columnTree = new View(viewId).def().layout
      //for i in [0...depth]
      //  columnTree = columnTree.subtrees[0]
      return this.readObj(columnTree, rootCellId);
    }
  };

  function glue(argsobj) {
    function value(a) {
      return a.qCellId != null ? a.qCellId.cellId : a;
    }
    function arg(a) {
      return _.isArray(a) ? a.map(value) : [value(a)];
    }
    return new function() {
      for (let k in argsobj) {
        let v = argsobj[k];
        this[k] = arg(v);
      }
      return null;
    };
  }

}
