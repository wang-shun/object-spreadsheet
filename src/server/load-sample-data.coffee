# Sample schema and data in a more human-friendly hierarchical format, which is
# interpreted by loadSampleData below.

# Shorthands:

# Simple value
V = (val) ->
  # {val: [{}]} does not work: val is treated as a literal field name.
  dict = {}
  dict[val] = [{}]
  dict

# Type _unit
U = (cell) -> {'_unit': [cell]}

# Type _token; value is not meaningful
T = (cellList) -> {'': cellList}

sampleSchema = [
  {
  type: '_token'
  cellName: 'Person'
  children: [
    {
    name: 'name'
    type: '_string'
    # TODO: Required, singleton; probably unique but maybe not in schema
    }
    {
    type: '_unit'
    cellName: 'Student'
    # No need to constrain singleton.
    children: [
      name: 'parent'
      type: 'Person'
      # There can be more than one parent, but there can be only one meeting per
      # enrollment, which we imagine several of the parents may attend if they
      # believe it is necessary.
    ]
    }
    # We don't flag parents explicitly.  A person is a parent by virtue of being
    # the parent of some student.
    {
    type: '_unit'
    cellName: 'Teacher'
    children: [
      {
      type: '_token'
      cellName: 'Slot'
      children: [
        {
        # We don't normally expect the time of an existing slot to change, but
        # I'm now thinking it's wiser not to try to enforce that by making the
        # time a direct child of Teacher when it has no direct meaning in the
        # context of the Teacher.  Such decisions won't always be clear. ~ Matt
        name: 'time'
        type: '_datetime' # TODO: define format
        }
      ]
      }
    ]
    }
  ]
  }
  {
  type: '_token'
  cellName: 'Class'
  children: [
    {
    name: 'code'
    type: '_string'
    # TODO: Required, singleton, unique
    }
    {
    name: 'name'
    type: '_string'
    # TODO: Required, singleton, unique (assuming department is sane)
    }
    {
    type: '_token'
    cellName: 'Section'
    children: [
      {
      name: 'teacher'
      type: 'Person.Teacher'
      # TODO: Required, singleton
      }
      {
      name: 'student'
      type: 'Person.Student'
      cellName: 'Enrollment'
      }
    ]
    }
  ]
  }
  {
  type: '_token'
  cellName: 'Meeting'
  children: [
    {
    name: 'enrollment'
    type: 'Class.Section.Enrollment'
    # TODO: Required, singleton, unique
    }
    {
    name: 'slot'
    type: 'Person.Teacher.Slot'
    # TODO: Required, singleton, unique
    }
    # TODO: Constraint slot.Teacher == enrollment.Teacher
  ]
  }
]

sampleData = {
  Person: T([
    {
    _id: '0'
    name: V('Daniel Jackson')
    Teacher: U({
      Slot: T([
        {_id: '0', time: V('2014-12-16 13:00')}
        {_id: '1', time: V('2014-12-16 13:15')}
        {_id: '2', time: V('2014-12-16 13:30')}
        {_id: '3', time: V('2014-12-16 13:45')}
      ])
    })
    }
    {
    _id: '1'
    name: V('Jonathan Edwards')
    Teacher: U({
      Slot: T([
        {_id: '4', time: V('2014-12-16 13:00')}
        {_id: '5', time: V('2014-12-16 14:00')}
      ])
    })
    }
    {
    _id: '2'
    name: V('Matt McCutchen')
    Student: U({
      parent: V('5')
    })
    }
    {
    _id: '3'
    name: V('Michael McCutchen')
    Student: U({
      parent: V('5')
    })
    }
    {
    _id: '4'
    name: V('Shachar Itzhaky')
    Student: U({
      parent: V('6')
    })
    }
    {
    _id: '5'
    name: V('Rosemary McCutchen')
    }
    {
    _id: '6'
    name: V('Yoram Itzhaky')
    }
  ])
  Class: T([
    {
    _id: '0'
    code: V('6.170')
    name: V('Software Studio')
    Section: T([
      {
      _id: '0'
      teacher: V('0')
      student: {
        '2': [{_id: '1'}]
        '3': [{_id: '3'}]
      }
      }
    ])
    }
    {
    _id: '1'
    code: V('6.*+~')
    name: V('Alloy')
    Section: T([
      {
      _id: '1'
      teacher: V('0')
      student: {
        '2': [{_id: '2'}]
        '4': [{_id: '4'}]
      }
      }
    ])
    }
    {
    _id: '2'
    code: V('6.:::')
    name: V('Managed Time')
    Section: T([
      {
      _id: '2'
      teacher: V('1')
      student: {
        '2': [{_id: '0'}]
      }
      }
    ])
    }
  ])
  Meeting: T([
    {
    enrollment: V(0)
    slot: V(4)
    }
    {
    enrollment: V(1)
    slot: V(1)
    }
    {
    enrollment: V(2)
    slot: V(2)
    }
    {
    enrollment: V(3)
    slot: V(3)
    }
    {
    enrollment: V(4)
    slot: V(0)
    }
  ])
}

Columns = new Mongo.Collection('columns')

loadSampleData = () ->
  isSpecial = (s) -> /^_/.test(s)

  # FIXME: More than 26
  orderTokenFromInt = (i) -> String.fromCharCode(65 + i)

  dbColumns = {}
  nextColumnId = 0

  # Add a super dict representing _unit, though it doesn't get an ID or anything.
  superSchema = {children: sampleSchema}

  scanColumns = (parentId, schema) ->
    schema.children ?= []
    schema.tmp_childIdxByName = {}
    for columnDef, i in schema.children
      if columnDef.name?
        schema.tmp_childIdxByName[columnDef.name] = i
      if columnDef.cellName?
        schema.tmp_childIdxByName[columnDef.cellName] = i
      thisId = (nextColumnId++).toString()
      columnDef.tmp_id = thisId
      dbColumns[thisId] = {
        _id: thisId
        parent: parentId
        orderToken: orderTokenFromInt(i)
        name: columnDef.name  # TODO: validate no name for type = _token
        tmp_typeStr: columnDef.type
        cellName: columnDef.cellName
        cells: {}
        formula: null  # no support yet
        tmp_nextCellId: 0
        tmp_usedCellIds: {}
      }
      scanColumns(thisId, columnDef)
  scanColumns('_unit', superSchema)

  # Now that IDs are assigned to all columns, we can resolve types to IDs.
  for id, dbColumn of dbColumns
    dbColumn.type =
      if isSpecial(dbColumn.tmp_typeStr)
        dbColumn.tmp_typeStr
      else
        c = superSchema
        for n in dbColumn.tmp_typeStr.split('.')
          # TODO: Accept only cellName?
          c = c.children[c.tmp_childIdxByName[n]]
        c.tmp_id
    delete dbColumn.tmp_typeStr

  # TODO: Support ordered lists once we figure out how that will work!
  iterateChildCells = (schema, cellData, callback) ->
    for colName, i of schema.tmp_childIdxByName  # Allow both name, cellName
      columnDef = schema.children[i]
      for value, childCellList of cellData[colName]  # OK if cellData[colName] is undefined
        for childCellData, twindex in childCellList
          callback(columnDef, value, twindex, childCellData)

  # Note which cell IDs are used in each column.
  scanCells = (schema, cellData) ->
    iterateChildCells(schema, cellData, (columnDef, value, twindex, childCellData) ->
      if childCellData._id?
        # TODO: assert not already true
        dbColumns[columnDef.tmp_id].tmp_usedCellIds[childCellData._id] = true
      scanCells(columnDef, childCellData)
    )
  scanCells(superSchema, sampleData)

  # Insert cells into columns.
  insertCells = (schema, cellData) ->
    iterateChildCells(schema, cellData, (columnDef, value, twindex, childCellData) ->
      dbCol = dbColumns[columnDef.tmp_id]
      if childCellData._id?
        thisId = childCellData._id
      else
        while (thisId = (dbCol.tmp_nextCellId++).toString()) of dbCol.tmp_usedCellIds
          ;
        childCellData._id = thisId
      dbCol.cells[thisId] = {
        parent: cellData._id
      }
      if dbCol.type == '_token'
        # In this case, the order gives the original token order.  Tokens could
        # be inserted or deleted in this order later.
        dbCol.cells[thisId].value = orderTokenFromInt(twindex)
        dbCol.cells[thisId].twindex = 0
      else
        # TODO: Will be a string from the input format.  Convert back to proper type.
        dbCol.cells[thisId].value = value
        dbCol.cells[thisId].twindex = twindex
      insertCells(columnDef, childCellData)
    )
  sampleData._id = '_unit'
  insertCells(superSchema, sampleData)

  # Insert columns into DB!
  for id, dbCol of dbColumns
    delete dbCol.tmp_nextCellId
    delete dbCol.tmp_usedCellIds
    Columns.insert(dbCol)

Meteor.startup () ->
  if Columns.find().count() == 0
    loadSampleData()
