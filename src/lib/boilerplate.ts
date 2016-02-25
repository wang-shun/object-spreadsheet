namespace Objsheets {

  if (Meteor.isClient) {
    let openCallbacks = [];
    let Relsheets = {
      open: (sheet, proceduresAppName : any = null) => {
        Tablespace["default"] = Tablespace.get(sheet);
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
      call: (transaction, argsObj, callback) => {
        $$.call("executeCannedTransaction", transaction, glue(argsObj), standardServerCallbackThen(callback));
      },
      onOpen: (callback) => {
        openCallbacks.push(callback);
      }
    };
  }

  if (Meteor.isServer) {
    Relsheets = {
      _procedures: {},
      procedures: function(appName, defs) {
        this._procedures[appName] = defs;
      },
      compile: function(appName) {
        // This may run multiple times; it should overwrite and not cause any problems.
        for (let name in this._procedures[appName]) {
          let preProc = this._procedures[appName][name];
          try {
            // NOTE: This is an interim implementation.  Once we have a basic
            // procedure editor, procedures will be loaded from dumps just like
            // column formulas.
            let params = preProc.params.map((p) => ({
                name: p[0],
                type: parseTypeStr(p[1]),
                singular: fallback(p[2], true)
              }));
            let proc = parseProcedure({
              name: name,
              params: params,
              body: preProc.body
            });
            let oldId = Procedures.findOne({
              name: name
            }) != null ? Procedures.findOne({
              name: name
            })._id : null;
            if (oldId != null) {
              $$.model.redefineProcedure(oldId, proc);
            } else {
              $$.model.defineProcedure(proc);
            }
          } catch (e) {
            // Incompatible schema change?
            console.log(`Failed to define app ${appName} sample procedure ${name} on sheet ${$$.id}:`, e.stack);
          }
        }
      }
    };

    Meteor.methods({
      compileProcedures: (cc, appName) => {
        cc.run(() => {
          Relsheets.compile(appName);
        });
      }
    });
  }

  Relsheets.readObj = (t, rootCellId : any = [], expandRefs : any = false, keyField : any = null, visited : any = null) => {
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
          let fam = vals.map((v) => Relsheets.readObj(x, cellIdChild(rootCellId, v), expandRefs, c.fieldName, visited));
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
            vals = vals.map((v) => Relsheets.readObj(ot, v, expandRefs, Columns.findOne(ot.root) != null ? Columns.findOne(ot.root).fieldName : null, visited));
          }
          obj[c.fieldName] = vals;
        }
      }
    }

    return obj;
  };

  // Future: Deprecate this in favor of something like readSubtree?
  Relsheets.read = function(viewId) {
    let layout = viewId != null ? ((new View(viewId).def()) != null ? (new View(viewId).def()).layout : null) || new Tree(rootColumnId) : View.rootLayout();
    return this.readObj(layout, [], true);
  };

  Relsheets.readSubtree = (columnStr, rootCellId) => {
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
    return Relsheets.readObj(columnTree, rootCellId);
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

  function exported(d) {
    var _results;
    _results = [];
    for (let k in d) {
      let v = d[k];
      _results.push(this[k] = v);
    }
    return _results;
  }

  exported({
    Relsheets: Relsheets
  });

}
