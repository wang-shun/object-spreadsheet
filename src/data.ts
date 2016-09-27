// XXX: The division of code between this file and common.coffee is not
// well-defined.  Define it and move things as necessary.

//COLUMN_COLLECTION = 'columns'
//CELLS_COLLECTION = 'cells'
// need them for publisher? maybe just use Columns._name, Cells._name?


namespace Objsheets {

  function scoped(obj: fixmeAny, name: fixmeAny, prop: fixmeAny) {
    Object.defineProperty(obj, name, prop);
  }

  export var $$: fixmeAny, Columns: fixmeAny, Cells: fixmeAny, Views: fixmeAny, Procedures: fixmeAny;
  scoped(Objsheets, "$$", {
    get: () => Tablespace.get()
  });
  for (let coll of ["Columns", "Cells", "Views", "Procedures"]) {
    ((coll: fixmeAny) => {
      scoped(Objsheets, coll, {
        get: () => $$[coll]
      });
    })(coll);  // Work around JavaScript variable capture semantics
  }

  // http://stackoverflow.com/a/25282455
  let tablespaceEnvVar = new Meteor.EnvironmentVariable();

  export class Tablespace {
    public lock: fixmeAny;
    public scheduled: fixmeAny;
    public formulaEngine: fixmeAny;
    public Columns: fixmeAny;
    public Cells: fixmeAny;
    public Views: fixmeAny;
    public Procedures: fixmeAny;
    public static defaultTablespace: fixmeAny;

    public static instances: {[id: string]: Tablespace} = {};

    public static get(id?: fixmeAny) {
      let v: fixmeAny;
      return id == null ? (Meteor.isServer && tablespaceEnvVar.get()) || Tablespace.defaultTablespace : (v = Tablespace.instances[id]) != null ? v : Tablespace.instances[id] = new Tablespace(id);
    }

    public run(func: fixmeAny = () => {}) {
      //Fiber = Npm.require('fibers')     # <-- tried to use Fiber.yield() but got "Fiber is a zombie" error ~~~~
      return tablespaceEnvVar.withValue(this, () => {
        if (this.lock) {
          this.scheduled.push(func);  // HACK
        } else {
          try {
            this.lock = 1;
            while (this.scheduled.length > 0) {
              this.scheduled.pop().apply(this);
            }
          } finally {
            this.lock = 0;
          }
          return func.apply(this);
        }
      });
    }

    // Convenience method;
    // calls a Meteor method, passing the current cc as first argument

    public call(method: fixmeAny, ...args: fixmeAny[]) {
      return Meteor.call.apply(Meteor, [method, this].concat(args));
    }

    constructor(public id: fixmeAny) {
      this.scheduled = [];
      this.lock = 0;
      if (Meteor.isServer) {
        // The constructor is called during Meteor method EJSON conversion, and
        // creating Mongo.Collections during that process causes various errors.
        // Defer until the control context is actually activated as part of the
        // Meteor method call.
        this.scheduled.push(() => {
          this.setupCollections();
          Tablespace.setupModelHook(this);
        });
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

    // Set by model.coffee

    public static setupModelHook: fixmeAny = null;

    public publish(collection: fixmeAny) {
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

    public runTransaction(op: fixmeAny) {
      return this.run(() => {
        let t = new Transaction();
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

    public static fromJSONValue(json: fixmeAny) {
      return Tablespace.get(json.id);
    }
  }

  EJSON.addType("Tablespace", Tablespace.fromJSONValue);

  function _toColumnId(selector: fixmeAny) {
    return fallback(selector._id, _.isRegExp(selector) ? parseColumnRef(selector.source)[0] : selector);
  }

  export class CellId {
    public columnId: fixmeAny;
    public cellId: fixmeAny;

    constructor({
        columnId: columnId,
        cellId: cellId
      }: fixmeAny) {
      this.columnId = _toColumnId(columnId);
      this.cellId = cellId;
    }

    public q(): QCellId {
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
      let c: CellId = this;
      let ancestors: fixmeAny = [];
      while (c != null) {
        ancestors.push(c);
        c = c.parent();
      }
      return ancestors;
    }

    public value(set?: fixmeAny, callback: fixmeAny = () => {}) {
      if (set != null) {
        this.remove();
        this.family().add(set, callback);
        // TypeScript --noImplicitReturns is flagging this.
        // TODO: Just get rid of MATLAB-style overloading...
        return undefined;
      } else {
        return cellIdLastStep(this.cellId);
      }
    }

    public family(columnId?: fixmeAny) {
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

    public remove(callback: fixmeAny = () => {}) {
      this.family().remove(this.value(), callback);
    }

    public ref() {
      return new TypedSet(this.columnId, set([this.cellId]));
    }

    public static root = new CellId({columnId: rootColumnId, cellId: []})
  }

  export class FamilyId {
    public columnId: ColumnId;
    public cellId: CellId1;

    constructor({
        columnId: columnId,
        cellId: cellId
      }: fixmeAny) {
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
      return new TypedSet(this.type(), <fixmeAny>set(this.values()));
    }

    public child(value: fixmeAny) {
      return new CellId({
        columnId: this.columnId,
        cellId: cellIdChild(this.cellId, value)
      });
    }

    public children() {
      return this.values().map((v: fixmeAny) => this.child(v));
    }

    // XXX: Should we change the database format so this is just a qFamilyId?

    public selector() {
      return {
        column: this.columnId,
        key: this.cellId
      };
    }

    public add(value: fixmeAny, callback: fixmeAny = (() => {}), consumePlaceholder: fixmeAny = false) {
      let updates = <fixmeAny>{
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

    public remove(value: fixmeAny, callback: fixmeAny = () => {}) {
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

    public addPlaceholder(callback: fixmeAny = () => {}) {
      // Careful... if we add a Cells entry in a state column with no "values"
      // property, evaluateAll won't automatically add the "values" property,
      // and the missing property will confuse various readers.
      if (Cells.findOne(this.selector()) == null) {
        let ce = <fixmeAny>this.selector();
        ce.values = [];
        Cells.insert(ce);
      }
      // If the field is initially absent, $inc treats it as 0.
      upsertOne(Cells, this.selector(), {
        $inc: {
          numPlaceholders: 1
        }
      }, callback);
    }

    public removePlaceholder(callback: fixmeAny = () => {}) {
      if (Cells.findOne(this.selector()) != null ? Cells.findOne(this.selector()).numPlaceholders : null) {  // XXX race
        updateOne(Cells, this.selector(), {
          $inc: {
            numPlaceholders: -1
          }
        }, callback);
      }
    }
  }

  export var rootCell = new CellId({
    columnId: rootColumnId,
    cellId: rootCellId
  });

  export function allCellIdsInColumnIgnoreErrors(columnId: fixmeAny) {
    if (columnId === rootColumnId) {
      return [rootCellId];
    }
    let cellIds: fixmeAny = [];
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

  function updateOne(collection: fixmeAny, selector: fixmeAny, modifier: fixmeAny, callback: fixmeAny) {
    let doc: fixmeAny;
    if ((doc = collection.findOne(selector)) != null) {
      collection.update(doc._id, modifier, callback);
    }
  }

  function upsertOne(collection: fixmeAny, selector: fixmeAny, modifier: fixmeAny, callback: fixmeAny) {
    let doc = collection.findOne(selector), id: fixmeAny;
    if (doc) {
      id = doc._id;
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
  export class CellsInMemory {
    public byColumn: fixmeAny;
    public byId: fixmeAny;
    public recycle: fixmeAny;



    constructor() {
      this.byColumn = {};
      this.byId = {};
      this.recycle = new EJSONKeyedMap();
    }

    public insert(doc: fixmeAny) {
      //console.log "[insert(#{JSON.stringify doc})]"
      let byKey: fixmeAny;
      if (doc._id == null) {
        doc._id = this.mkId(doc);
      }
      let column = doc.column;
      let key = doc.key;
      this.byColumn[column] = byKey = fallback(this.byColumn[column], new EJSONKeyedMap());
      //**  assume !byKey.get(key)?  **#
      byKey.set(key, doc);
      this.byId[doc._id] = doc;
      return doc._id;
    }

    public mkId(doc: fixmeAny) {
      let fid: fixmeAny, rec: fixmeAny;
      if ((rec = this.recycle.get([doc.column, doc.key])) != null) {
        return rec;
      } else {
        do {
          fid = _freshId();
        } while (this.byId[fid] != null);
        return fid;
      }
    }

    public findOne(query: fixmeAny) {
      let column: fixmeAny, key: fixmeAny;
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
          return undefined;
        }
      } else {
        throw Error(`unimplemented [findOne(query=${JSON.stringify(query)})]`);
      }
    }

    public find(query: fixmeAny) {
      return {
        forEach: (cb: fixmeAny) => {
          for (let _id in this.byId) {
            let doc = this.byId[_id];
            if (doc.dirty === query.dirty) {
              cb(doc);
            }
          }
        }
      };
    }

    public update(query: fixmeAny, modifier: fixmeAny, options: fixmeAny) {
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
            doc[k] = doc[k].filter((x: fixmeAny) => !EJSON.equals(x, v));
          }
        } else if (k === "$addToSet") {
          for (let k in v0) {
            let v = v0[k];
            let l = doc[k];
            if (l.every((x: fixmeAny) => !EJSON.equals(x, v))) {
              l.push(v);
            }
          }
        } else if (k[0] === "$") {
          throw Error(`unimplemented [update(query=${s(query)}, modifier=${s(modifier)}, options=${s(options)}) doc=${s(doc)}]`);
        } else {
          doc[k] = _.clone(v0);
        }
      }
      //console.log "  >> #{JSON.stringify doc}"
    }

    public upsert(query: fixmeAny, modifier: fixmeAny, options: fixmeAny) {
      if (options != null) {
        throw Error("unimplemented upsert(..., options)");
      }
      this.update(query, modifier, {
        upsert: true
      });
    }

    public remove(query: fixmeAny, callback: fixmeAny = () => {}) {
      let column: fixmeAny, key: fixmeAny;
      if ((column = query.column) != null) {
        let byKey = this.byColumn[column];
        if ((key = query.key) != null) {
          let doc = byKey.get(key);
          if (doc != null) {
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

    public stash(doc: fixmeAny) {
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
    public mem: fixmeAny;

    constructor(public dbCells: fixmeAny) {
      //@mem = new Mongo.Collection(null)
      this.mem = new CellsInMemory();
    }

    public prefetch() {
      for (let doc of this.dbCells.find().fetch()) {
        this.mem.insert(doc);
      }
    }

    public insert(doc: fixmeAny) {
      doc = _.clone(doc);
      doc.dirty = true;
      this.mem.insert(doc);
    }

    public update(query: fixmeAny, values: fixmeAny, upsert: fixmeAny = false) {
      if (_.size(values) !== 1) {
        throw new Error(`unsupported update in transaction: '${EJSON.stringify(values)}'`);
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
        throw new Error(`unsupported update in transaction: '${EJSON.stringify(values)}'`);
      }
      if (upsert) {
        this.mem.upsert(query, values);
      } else {
        this.mem.update(query, values);
      }
    }

    public upsert(query: fixmeAny, values: fixmeAny) {
      this.update(query, values, true);
    }

    public remove(query: fixmeAny = {}) {
      this.mem.remove(query);  // nothing fancy here...
    }

    public find(query: fixmeAny = {}) {
      return this.mem.find(query);
    }

    public findOne(query: fixmeAny = {}) {
      return this.mem.findOne(query);
    }

    public commit() {
      let raw = this.dbCells.rawCollection();
      this.dbCells.find().forEach((doc: fixmeAny) => {
        if (!this.mem.findOne(doc._id)) {
          raw.remove({
            _id: doc._id
          }, (err: fixmeAny) => {
            if (err != null) {
              console.log(`remove: ${err}`);
            }
          });
          //@dbCells.remove(doc._id)
        }
      });
      this.mem.find({
        dirty: true
      }).forEach((doc: fixmeAny) => {
        delete doc.dirty;
        raw.update({
          _id: doc._id
        }, doc, {
          upsert: true
        }, (err: fixmeAny) => {
          if (err != null) {
            console.log(`remove: ${err}`);
          }
        });
        //@dbCells.upsert(doc._id, doc)
      });
    }
  }

  export class Transaction {
    public Cells: fixmeAny;

    constructor(dbCells?: fixmeAny) {
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

}
