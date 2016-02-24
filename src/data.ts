// XXX: The division of code between this file and common.coffee is not
// well-defined.  Define it and move things as necessary.

//COLUMN_COLLECTION = 'columns'
//CELLS_COLLECTION = 'cells'
// need them for publisher? maybe just use Columns._name, Cells._name?


function scoped(name, prop) {
  Object.defineProperty(this, name, prop);
}

scoped("$$", {
  get: () => Tablespace.get()
});
for (let coll of ["Columns", "Cells", "Views", "Procedures"]) {
  ((coll) => {
    scoped(coll, {
      get: () => $$[coll]
    });
  })(coll);  // Work around JavaScript variable capture semantics
}

class Tablespace extends ControlContext {
  public formulaEngine;
  public Columns;
  public Cells;
  public Views;
  public Procedures;

  constructor(public id) {
    super();
    if (Meteor.isServer) {
      // The constructor is called during Meteor method EJSON conversion, and
      // creating Mongo.Collections during that process causes various errors.
      // Defer until the control context is actually activated as part of the
      // Meteor method call.
      // Notice that model.coffee uses @do to initialize the model. @setupCollections
      // must happen before that. Hence this is a hack.
      this["do"](this.setupCollections);
    }
    if (Meteor.isClient) {
      // This is safe, and the client does not activate control contexts.
      this.setupCollections();
      // Better ideas where to put this?  On the server, it's done in model.coffee.
      this.formulaEngine = new FormulaEngine();
    }
  }

  public setupCollections() {
    console.log(`created Tablespace[${this.id}]`);
    // PROBLEM! Creating Mongo.Collection yields execution, which makes all sorts
    // of race conditions.
    this.Columns = new Mongo.Collection(`${this.id}:columns`);
    this.Cells = new Mongo.Collection(`${this.id}:cells`);
    this.Views = new Mongo.Collection(`${this.id}:views`);
    this.Procedures = new Mongo.Collection(`${this.id}:procedures`);
    if (Meteor.isServer) {
      for (let collection of [this.Columns, this.Cells, this.Views, this.Procedures]) {
        this.publish(collection);
      }
      this.Cells.allow({
        insert: (() => true),
        update: (() => true),
        remove: (() => true)
      });
      this.Views.allow({
        insert: (() => true),
        update: (() => true),
        remove: (() => true)
      });
    }
  }

  public publish(collection) {
    // Do not inline this into the same function as the loop over collections, or
    // the reference to "collection" from the publish function will see the wrong
    // value of the variable (insane JavaScript semantics).
    Meteor.publish(collection._name, () => collection.find());
  }

  public subscribeAll() {
    for (let collection of [this.Columns, this.Cells, this.Views]) {
      Meteor.subscribe(collection._name);
    }
  }

  public runTransaction(op) {
    return this.run(() => {
      let t = new Transaction;
      t.begin();
      try {
        let ret = op();
        t.commit();
        return ret;
      } catch (e) {
        t.rollback();
        throw e;
      }
    });
  }

  public typeName() {
    return "Tablespace";
  }

  public toJSONValue() {
    return {
      id: this.id
    };
  }

  public static fromJSONValue(json) {
    return Tablespace.get(json.id);
  }
}

EJSON.addType("Tablespace", Tablespace.fromJSONValue);

function _toColumnId(selector) {
  return fallback(selector._id, _.isRegExp(selector) ? parseColumnRef(selector.source)[0] : selector);
}

class CellId {
  public columnId;
  public cellId;

  constructor({
      columnId: columnId,
      cellId: cellId
    }) {
    this.columnId = _toColumnId(columnId);
    this.cellId = cellId;
  }

  public q() {
    return {
      columnId: this.columnId,
      cellId: this.cellId
    };
  }

  public parent() {
    let c = getColumn(this.columnId);
    return c && (c.parent != null) ? new CellId({
      columnId: c.parent,
      cellId: cellIdParent(this.cellId)
    }) : null;
  }

  public ancestors() {
    let c = this;
    let ancestors = [];
    while (c != null) {
      ancestors.push(c);
      c = c.parent();
    }
    return ancestors;
  }

  public value(set, callback : any = () => {}) {
      if (set != null) {
        this.remove();
        this.family().add(set, callback);
      } else {
        return cellIdLastStep(this.cellId);
      }
  }

  public family(columnId) {
    return columnId != null ? new FamilyId({
      columnId: columnId,
      cellId: this.cellId
    }) : new FamilyId({
      columnId: this.columnId,
      cellId: cellIdParent(this.cellId)
    });
  }

  public families() {
    return fallback(getColumn(this.columnId) != null ? getColumn(this.columnId).children : null, []).map((childId) => this.family(childId));
  }

  public remove(callback : any = () => {}) {
      this.family().remove(this.value(), callback);
  }

  public ref() {
    return new TypedSet(this.columnId, set([this.cellId]));
  }
}

class FamilyId {
  public columnId;
  public cellId;

  constructor({
      columnId: columnId,
      cellId: cellId
    }) {
    this.columnId = _toColumnId(columnId);
    this.cellId = cellId;
  }

  public parent() {
    let c = getColumn(this.columnId);
    return c && (c.parent != null) ? new CellId({
      columnId: c.parent,
      cellId: this.cellId
    }) : null;
  }  // returns a qCellId

  public ancestors() {
    return this.parent().ancestors();
  }

  public read() {
    return Cells.findOne({
      column: this.columnId,
      key: this.cellId
    });
  }

  // Ignores erroneous families.
  // FIXME: Review all callers and implement error propagation where appropriate.

  public values() {
    return fallback(this.read() != null ? this.read().values : null, []);
  }

  public type() {
    return Columns.findOne(this.columnId).type;
  }

  public typedValues() {
    return new TypedSet(this.type(), set(this.values()));
  }

  public child(value) {
    return new CellId({
      columnId: this.columnId,
      cellId: cellIdChild(this.cellId, value)
    });
  }

  public children() {
    return this.values().map((v) => this.child(v));
  }

  // XXX: Should we change the database format so this is just a qFamilyId?

  public selector() {
    return {
      column: this.columnId,
      key: this.cellId
    };
  }

  public add(value, callback : any = (() => {}), consumePlaceholder : any = false) {
    let updates = {
      $addToSet: {
        values: value
      }
    };
    if (consumePlaceholder && (Cells.findOne(this.selector()) != null ? Cells.findOne(this.selector()).numPlaceholders : null)) {
      updates.$inc = {
        numPlaceholders: -1
      };
    }
    upsertOne(Cells, this.selector(), updates, callback);
    return this.child(value);
  }

  public remove(value, callback : any = () => {}) {
      if (getColumn(this.columnId).isObject) {
        Meteor.call("recursiveDeleteStateCellNoInvalidate", $$, this.columnId, cellIdChild(this.cellId, value), callback);
      } else {
        // optimization: deleting a single value is faster that way
        // Use updateOne instead of update, since client is not allowed
        // to update documents via selector, only by id
        updateOne(Cells, {
          column: this.columnId,
          key: this.cellId
        }, {
          $pull: {
            values: value
          }
        }, callback);
      }
  }

  public addPlaceholder(callback : any = () => {}) {
      // If the field is initially absent, $inc treats it as 0.
      upsertOne(Cells, this.selector(), {
        $inc: {
          numPlaceholders: 1
        }
      }, callback);
  }

  public removePlaceholder(callback : any = () => {}) {
      if (Cells.findOne(this.selector()) != null ? Cells.findOne(this.selector()).numPlaceholders : null) {  // XXX race
        updateOne(Cells, this.selector(), {
          $inc: {
            numPlaceholders: -1
          }
        }, callback);
      }
  }
}

let rootCell = CellId.ROOT = new CellId({
  columnId: rootColumnId,
  cellId: rootCellId
});

function allCellIdsInColumnIgnoreErrors(columnId) {
  if (columnId === rootColumnId) {
    return [rootCellId];
  }
  let cellIds = [];
  for (let family of Cells.find({
    column: columnId
  }).fetch()) {
    if (family.values != null) {
      for (let v of family.values) {
        cellIds.push(cellIdChild(family.key, v));
      }
    }
  }
  return cellIds;
}

// Helpers to access collections from the client, which is only allowed to select
// documents by ID.

function updateOne(collection, selector, modifier, callback) {
  var doc;
  if ((doc = collection.findOne(selector)) != null) {
    collection.update(doc._id, modifier, callback);
  }
}

function upsertOne(collection, selector, modifier, callback) {
  let doc = collection.findOne(selector);
  if (doc) {
    let id = doc._id;
  } else {
    id = collection.insert(selector);
  }
  collection.update(id, modifier, callback);
}

let _cnt = 0;
  function _freshId() {
    _cnt += 1;
    return `cim.${_cnt}`;
  };
class CellsInMemory {
  public byColumn;
  public byId;
  public recycle;



  constructor() {
    this.byColumn = {};
    this.byId = {};
    this.recycle = new EJSONKeyedMap;
  }

  public insert(doc) {
    //console.log "[insert(#{JSON.stringify doc})]"
    var byKey;
    if (doc._id == null) {
      doc._id = this.mkId(doc);
    }
    let column = doc.column;
    let key = doc.key;
    this.byColumn[column] = byKey = fallback(this.byColumn[column], new EJSONKeyedMap);
    //**  assume !byKey.get(key)?  **#
    byKey.set(key, doc);
    this.byId[doc._id] = doc;
    return doc._id;
  }

  public mkId(doc) {
    var fid, rec;
    if ((rec = this.recycle.get([doc.column, doc.key])) != null) {
      return rec;
    } else {
      while (this.byId[fid = _freshId()] != null) {
        0;
      }
      return fid;
    }
  }

  public findOne(query) {
    var column, key;
    if (_.isString(query)) {
      return this.byId[query];
    } else if ((column = query.column) != null) {
      let byKey = this.byColumn[column];
      if (byKey != null) {
        if ((key = query.key) != null) {
          return byKey.get(key);
        } else {
          throw Error(`unimplemented [findOne(query=${JSON.stringify(query)})]`);
        }
      } else {
        return null;
      }
    } else {
      throw Error(`unimplemented [findOne(query=${JSON.stringify(query)})]`);
    }
  }

  public find(query) {
    return {
      forEach: (cb) => {
        for (let _id in this.byId) {
          let doc = this.byId[_id];
          if (doc.dirty === query.dirty) {
            cb(doc);
          }
        }
      }
    };
  }

  public update(query, modifier, options) {
    //console.log "[update(#{JSON.stringify query}, #{JSON.stringify modifier}, #{JSON.stringify options})]"
    let doc = this.findOne(query);
    //console.log "  << #{JSON.stringify doc}"
    if ((doc == null) && (options != null ? options.upsert : null)) {
      //** assert query.key? and query.column? **#
      doc = {};
      for (let k in query) {
        let v = query[k];
        doc[k] = _.clone(v);
      }
      this.insert(doc);
    }
    let s = JSON.stringify;
    for (let k in modifier) {
      let v0 = modifier[k];
      if (k === "$set") {
        for (let k in v0) {
          let v = v0[k];
          doc[k] = _.clone(v);
        }
      } else if (k === "$pull") {
        for (let k in v0) {
          let v = v0[k];
          doc[k] = doc[k].filter((x) => !EJSON.equals(x, v));
        }
      } else if (k === "$addToSet") {
        for (let k in v0) {
          let v = v0[k];
          let l = doc[k];
          if (l.every((x) => !EJSON.equals(x, v))) {
            l.push(v);
          }
        }
      } else if (k[0] === "$") {
        throw Error(`unimplemented [update(query=${s(query)}, modifier=${s(modifier)}, options=${s(options)}) doc=${s(doc)}]`);
      } else {
        doc[k] = _.clone(v);
      }
    }
    //console.log "  >> #{JSON.stringify doc}"
  }

  public upsert(query, modifier, options) {
    if (options != null) {
      throw Error("unimplemented upsert(..., options)");
    }
    this.update(query, modifier, {
      upsert: true
    });
  }

  public remove(query, callback : any = () => {}) {
      if ((column = query.column) != null) {
        let byKey = this.byColumn[column];
        if ((key = query.key) != null) {
          if ((doc = byKey.get(key)) != null) {
            this.stash(doc);
            byKey["delete"](key);
          }
        } else {
          if (byKey != null) {
            for (let k in byKey.obj) {
              let doc = byKey.obj[k];
              this.stash(doc);
            }
            delete this.byColumn[column];
          }
        }
      } else {
        if ((key = query.key) != null) {
          for (let k in this.byColumn) {
            let v = this.byColumn[k];
            this.remove({
              column: k,
              key: key
            });
          }
        } else {
          this.byColumn = {};
          this.byId = {};
        }
      }

      callback();
  }

  public stash(doc) {
    //console.log "  stash[doc=#{JSON.stringify doc}]"
    delete this.byId[doc._id];
    this.recycle.set([doc.column, doc.key], doc._id);
  }
}

//
// Provides transaction-like behaviour by taking a snapshot of the
// Cells collection in memory, manipulating it and then storing the
// changes back to the Mongo collection.
//
class TransactionCells {
  public mem;

  constructor(public dbCells) {
    //@mem = new Mongo.Collection(null)
    this.mem = new CellsInMemory;
  }

  public prefetch() {
    for (let doc of this.dbCells.find().fetch()) {
      this.mem.insert(doc);
    }
  }

  public insert(doc) {
    doc = _.clone(doc);
    doc.dirty = true;
    this.mem.insert(doc);
  }

  public update(query, values, upsert : any = false) {
    if (_.size(values) !== 1) {
      throw new Exception(`unsupported update in transaction: '${EJSON.stringify(values)}'`);
    }
    if (values.$set != null) {
      values = _.clone(values);
      values.$set.dirty = true;
    } else if ((values.$pull != null) || (values.$addToSet != null)) {
      values = _.clone(values);
      values.$set = {
        dirty: true
      };
    } else {
      throw new Exception(`unsupported update in transaction: '${EJSON.stringify(values)}'`);
    }
    if (upsert) {
      this.mem.upsert(query, values);
    } else {
      this.mem.update(query, values);
    }
  }

  public upsert(query, values) {
    this.update(query, values, true);
  }

  public remove(query : any = {}) {
    this.mem.remove(query);  // nothing fancy here...
  }

  public find(query : any = {}) {
    return this.mem.find(query);
  }

  public findOne(query : any = {}) {
    return this.mem.findOne(query);
  }

  public commit() {
    let raw = this.dbCells.rawCollection();
    this.dbCells.find().forEach((doc) => {
      if (!this.mem.findOne(doc._id)) {
        raw.remove({
          _id: doc._id
        }, (err) => err != null ? console.log(`remove: ${err}`) : null);
        //@dbCells.remove(doc._id)
      }
    });
    this.mem.find({
      dirty: true
    }).forEach((doc) => {
      delete doc.dirty;
      raw.update({
        _id: doc._id
      }, doc, {
        upsert: true
      }, (err) => err != null ? console.log(`remove: ${err}`) : null);
      //@dbCells.upsert(doc._id, doc)
    });
  }
}

class Transaction {
  public Cells;

  constructor(dbCells) {
    this.Cells = new TransactionCells(fallback(dbCells, Cells));
  }

  public begin() {
    this.Cells.prefetch();
    $$.Cells = this.Cells;
  }

  public rollback() {
    $$.Cells = this.Cells.dbCells;
  }

  public commit() {
    this.Cells.commit();
    $$.Cells = this.Cells.dbCells;
  }
}

exported({
  Tablespace: Tablespace,
  CellId: CellId,
  FamilyId: FamilyId,
  rootCell: rootCell,
  allCellIdsInColumnIgnoreErrors: allCellIdsInColumnIgnoreErrors,
  Transaction: Transaction,
  CellsInMemory: CellsInMemory
});
