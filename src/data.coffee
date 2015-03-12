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
    console.log "created Tablespace[#{@id}]"
    @Columns = new Mongo.Collection "#{@id}:columns"
    @Cells   = new Mongo.Collection "#{@id}:cells"
    @Views   = new Mongo.Collection "#{@id}:views"
    for c in [@Columns,@Cells,@Views]
      @publishSubscribe c
    super()

  publishSubscribe: (collection) ->
    if Meteor.isServer then Meteor.publish collection._name, -> collection.find()
    if Meteor.isClient then Meteor.subscribe collection._name

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

  # NOTE: "callback" is supported only on the client.

  add: (key, value, callback=->) ->
    if Meteor.isServer
      $$.model.invalidateDataCache()
      Cells.upsert {column: @columnId, key}, {$addToSet: {values: value}}
      $$.model.evaluateAll()
    else
      $$.call 'ColumnBinRel_add', @columnId, key, value, callback

  remove: (key, value, callback=->) ->
    if !value?
      cellId = key
      key = cellIdParent(cellId)
      value = cellIdLastStep(cellId)
    if Meteor.isServer
      $$.model.invalidateDataCache()
      Cells.update {column: @columnId, key}, {$pull: {values: value}}
      $$.model.evaluateAll()
    else
      $$.call 'ColumnBinRel_remove', @columnId, key, value, callback

  ## remove(key, oldValue) + add(key, newValue) in a single operation
  removeAdd: (key, oldValue, newValue, callback=->) ->
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


#
# Provides transaction-like behaviour by taking a snapshot of the
# Cells collection in memory, manipulating it and then storing the
# changes back to the Mongo collection.
#
class Transaction
  
  class @Cells
    
    constructor: (@dbCells) ->
      @mem = new Mongo.Collection(null)
      
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
      @dbCells.find().forEach (doc) =>
        if ! @mem.findOne(doc._id)
          @dbCells.remove(doc._id)
      @mem.find({dirty: true}).forEach (doc) =>
        delete doc.dirty
        @dbCells.upsert(doc._id, doc)
    
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
      cc.run -> new ColumnBinRel(columnId).add(key, value)
    ColumnBinRel_remove: (cc, columnId, key, value) ->
      cc.run -> new ColumnBinRel(columnId).remove(key, value)
    ColumnBinRel_removeAdd: (cc, columnId, key, oldValue, newValue) ->
      cc.run -> new ColumnBinRel(columnId).removeAdd(key, oldValue, newValue)


exported {Tablespace, ColumnBinRel, PairsBinRel, Transaction}
