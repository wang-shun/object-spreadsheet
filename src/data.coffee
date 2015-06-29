#COLUMN_COLLECTION = 'columns'
#CELLS_COLLECTION = 'cells'
# need them for publisher? maybe just use Columns._name, Cells._name?

scoped = (name, prop) -> Object.defineProperty @, name, prop

scoped '$$', get: -> Tablespace.get()
scoped 'Columns', get: -> $$.Columns
scoped 'Cells',   get: -> $$.Cells
scoped 'Views',   get: -> $$.Views


class Tablespace extends ControlContext
  constructor: (@id) ->
    super()
    if Meteor.isServer
      # The constructor is called during Meteor method EJSON conversion, and
      # creating Mongo.Collections during that process causes various errors.
      # Defer until the control context is actually activated as part of the
      # Meteor method call.
      @do(@setupCollections)
    if Meteor.isClient
      # This is safe, and the client does not activate control contexts.
      @setupCollections()

  setupCollections: () ->
    console.log "created Tablespace[#{@id}]"
    @Columns = new Mongo.Collection "#{@id}:columns"
    @Cells   = new Mongo.Collection "#{@id}:cells"
    @Views   = new Mongo.Collection "#{@id}:views"
    if Meteor.isServer
      for collection in [@Columns,@Cells,@Views]
        @publish collection

  publish: (collection) ->
    # Do not inline this into the same function as the loop over collections, or
    # the reference to "collection" from the publish function will see the wrong
    # value of the variable (insane JavaScript semantics).
    Meteor.publish collection._name, -> collection.find()

  subscribeAll: () ->
    for collection in [@Columns,@Cells,@Views]
      Meteor.subscribe collection._name

  runTransaction: (op) ->
    @run ->
      t = new Transaction
      t.begin()
      try
        ret = op()
        t.commit()
        ret
      catch e
        t.rollback()
        throw e
    
  typeName: -> 'Tablespace'
  toJSONValue: -> {@id}
  @fromJSONValue: (json) => @get json.id

EJSON.addType('Tablespace', Tablespace.fromJSONValue)


# NOTE: This class treats erroneous families in formula columns as empty!  Do
# not use it if you care about error propagation.
class ColumnBinRel
  constructor: (@columnId) ->

  cells: ->
    families = Cells.find({column: @columnId}).fetch()
    famcells = (family) -> ([family.key, v] for v in family.values || [])
    [].concat((famcells x for x in families)...)

  cellset: ->
    c = Columns.findOne(@columnId)
    new TypedSet([c.parent, c.type], set(@cells()))

  # NOTE: "callback" is supported only on the client, and "evaluate" is
  # supported only on the server (calls from the client always evaluate).

  add: (key, value, callback=(->), evaluate=true) ->
    if Meteor.isServer
      $$.model.invalidateDataCache()
      Cells.upsert {column: @columnId, key}, {$addToSet: {values: value}}
      if evaluate
        $$.model.evaluateAll()
    else
      $$.call 'ColumnBinRel_add', @columnId, key, value, callback

  remove: (key, value, callback=(->), evaluate=true) ->
    if !value?
      cellId = key
      key = cellIdParent(cellId)
      value = cellIdLastStep(cellId)
    if Meteor.isServer
      $$.model.invalidateDataCache()
      Cells.update {column: @columnId, key}, {$pull: {values: value}}
      if evaluate
        $$.model.evaluateAll()
    else
      $$.call 'ColumnBinRel_remove', @columnId, key, value, callback

  ## remove(key, oldValue) + add(key, newValue) in a single operation
  removeAdd: (key, oldValue, newValue, callback=(->), evaluate=true) ->
    if !oldValue?
      cellId = key
      key = cellIdParent(cellId)
      oldValue = cellIdLastStep(cellId)
    if ! EJSON.equals(oldValue, newValue)
      if Meteor.isServer
        # This WOULD have been nice, but is not supported (Mongo ticket SERVER-1050)
        #Cells.upsert {column: @columnId, key}, {$pull: {values: oldValue}, $addToSet: {values: newValue}}
        $$.model.invalidateDataCache()
        Cells.update {column: @columnId, key}, {$pull: {values: oldValue}}
        Cells.upsert {column: @columnId, key}, {$addToSet: {values: newValue}}
        if evaluate
          $$.model.evaluateAll()
      else
        $$.call 'ColumnBinRel_removeAdd', @columnId, key, oldValue, newValue, callback

  lookup: (keys) ->
    # @param keys: an EJSONKeyedSet or TypedSet
    # @return a TypedSet with matching values from column, {x.column | x in keys}
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    cells = @cells()
    c = Columns.findOne(@columnId)
    values = set(cell[1] for cell in cells when keys.has cell[0])
    new TypedSet(c.type, values)


class PairsBinRel
  constructor: (@pairs, @domainType='_any', @rangeType='_any') ->

  cells: -> @pairs

  cellset: -> new TypedSet([@domainType, @rangeType], set(@pairs))

  lookup: (keys) ->
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    values = set(cell[1] for cell in @pairs when keys.has cell[0])
    new TypedSet(@rangeType, values)

  transpose: ->
    sriap = ([x[1], x[0]] for x in @pairs)
    new PairsBinRel(sriap, @rangeType, @domainType)


class CellsInMemory

  _cnt = 0
  _freshId = -> _cnt += 1 ; "cim.#{_cnt}"

  constructor: ->
    @byColumn = {}
    @byId = {}
    @recycle = new EJSONKeyedMap

  insert: (doc) ->
    #console.log "[insert(#{JSON.stringify doc})]"
    if !doc._id?
      doc._id = @mkId(doc)
    column = doc.column ; key = doc.key
    @byColumn[column] = byKey = @byColumn[column] ? new EJSONKeyedMap
    #**  assume !byKey.get(key)?  **#
    byKey.set(key, doc)
    @byId[doc._id] = doc
    doc._id

  mkId: (doc) ->
    if (rec = @recycle.get([doc.column, doc.key]))?
      rec
    else
      while @byId[fid = _freshId()]? then 0
      fid

  findOne: (query) ->
    if _.isString(query)
      @byId[query]
    else if (column = query.column)?
      byKey = @byColumn[column]
      if byKey?
        if (key = query.key)?
          byKey.get(key)
        else
          throw Error "unimplemented [findOne(query=#{JSON.stringify(query)})]"
      else
        undefined
    else
      throw Error "unimplemented [findOne(query=#{JSON.stringify(query)})]"

  find: (query) ->
    forEach: (cb) =>
      for _id, doc of @byId
        if doc.dirty == query.dirty
          cb(doc)

  update: (query, modifier, options) ->
    #console.log "[update(#{JSON.stringify query}, #{JSON.stringify modifier}, #{JSON.stringify options})]"
    doc = @findOne(query)
    #console.log "  << #{JSON.stringify doc}"
    if !doc? && options?.upsert
      #** assert query.key? and query.column? **#
      doc = {}
      for k, v of query then doc[k] = _.clone(v)
      @insert(doc)
    s = JSON.stringify
    for k, v0 of modifier
      if k == "$set"
        for k, v of v0
          doc[k] = _.clone(v)
      else if k == "$pull"
        for k, v of v0
          doc[k] = (x for x in doc[k] when !EJSON.equals(x, v))
      else if k == "$addToSet"
        for k, v of v0
          l = doc[k]
          if l.every((x) -> !EJSON.equals(x, v)) then l.push(v)
      else if k[0] == "$"
        throw Error "unimplemented [update(query=#{s query}, modifier=#{s modifier}, options=#{s options}) doc=#{s doc}]"
      else
        doc[k] = _.clone(v)
    #console.log "  >> #{JSON.stringify doc}"

  upsert: (query, modifier, options) ->
    if options? then throw Error "unimplemented upsert(..., options)"
    @update(query, modifier, {upsert: true})

  remove: (query) ->
    if (column = query.column)?
      byKey = @byColumn[column]
      if (key = query.key)?
        if (doc = byKey[key])?
          @stash(doc)
          byKey.delete(key)
      else
        if byKey?
          for k, doc of byKey.obj
            @stash(doc)
          delete @byColumn[column]
    else
      if (key = query.key)?
        for k, v of @byColumn
          @remove {column: k, key: key}
      else
        @byColumn = {}
        @byId = {}

  stash: (doc) ->
    #console.log "  stash[doc=#{JSON.stringify doc}]"
    delete @byId[doc._id]
    @recycle.set([doc.column, doc.key],  doc._id)

#
# Provides transaction-like behaviour by taking a snapshot of the
# Cells collection in memory, manipulating it and then storing the
# changes back to the Mongo collection.
#
class Transaction
  
  class @Cells
    
    constructor: (@dbCells) ->
      #@mem = new Mongo.Collection(null)
      @mem = new CellsInMemory
      
    prefetch: ->
      @mem.insert(doc) for doc in @dbCells.find().fetch()
        
    insert: (doc) ->
      doc = _.clone(doc)
      doc.dirty = true
      @mem.insert(doc)
      
    update: (query, values, upsert=false) ->
      if _.size(values) != 1
        throw new Exception("unsupported update in transaction: '#{EJSON.stringify values}'")
      if values.$set?
        values = _.clone(values)
        values.$set.dirty = true
      else if values.$pull? || values.$addToSet?
        values = _.clone(values)
        values.$set = {dirty: true}
      else
        throw new Exception("unsupported update in transaction: '#{EJSON.stringify values}'")
      if upsert
        @mem.upsert(query, values)
      else
        @mem.update(query, values)
        
    upsert: (query, values) ->
      @update(query, values, true)
      
    remove:  (query={})  ->  @mem.remove(query) # nothing fancy here...
    find:    (query={})  ->  @mem.find(query)
    findOne: (query={})  ->  @mem.findOne(query)
    
    commit: ->
      raw = @dbCells.rawCollection()
      @dbCells.find().forEach (doc) =>
        if ! @mem.findOne(doc._id)
          raw.remove({_id: doc._id}, (err) -> if err? then console.log "remove: #{err}")
          #@dbCells.remove(doc._id)
      @mem.find({dirty: true}).forEach (doc) =>
        delete doc.dirty
        raw.update({_id: doc._id}, doc, {upsert: true}, (err) -> if err? then console.log "remove: #{err}")
        #@dbCells.upsert(doc._id, doc)
    
  constructor: (dbCells) ->
    @Cells = new Transaction.Cells(dbCells ? Cells)
    
  begin: ->
    @Cells.prefetch()
    $$.Cells = @Cells
    
  rollback: ->
    $$.Cells = @Cells.dbCells
    undefined
    
  commit: ->
    @Cells.commit()
    $$.Cells = @Cells.dbCells
    undefined

        
      
if Meteor.isServer
  Meteor.methods
    ColumnBinRel_add: (cc, columnId, key, value) ->
      cc.runTransaction -> new ColumnBinRel(columnId).add(key, value)
    ColumnBinRel_remove: (cc, columnId, key, value) ->
      cc.runTransaction -> new ColumnBinRel(columnId).remove(key, value)
    ColumnBinRel_removeAdd: (cc, columnId, key, oldValue, newValue) ->
      cc.runTransaction -> new ColumnBinRel(columnId).removeAdd(key, oldValue, newValue)


exported {Tablespace, ColumnBinRel, PairsBinRel, Transaction}
