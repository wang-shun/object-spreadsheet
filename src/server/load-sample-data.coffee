@loadSampleData = () ->
  # Sample schema and data in a more human-friendly hierarchical format.

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

  # Shorthands:

  # Simple value(s)
  V = () -> ([val, {}] for val in arguments)

  # Type _unit
  U = (cell) -> [['_unit', cell]]

  # Type _token: successive integer tokens for now.
  T = (cellList) -> ([i.toString(), cell] for cell, i in cellList)

  I = () -> (x.toString() for x in arguments)

  # _mark is used only to refer to a cell within this input format.  IDs will be
  # assigned by the loading code.
  sampleData = {
    Person: T([
      {
      name: V('Daniel Jackson')
      Teacher: U({
        Slot: T([
          {time: V('2014-12-16 13:00')}
          {time: V('2014-12-16 13:15')}
          {time: V('2014-12-16 13:30')}
          {time: V('2014-12-16 13:45')}
        ])
      })
      }
      {
      name: V('Jonathan Edwards')
      Teacher: U({
        Slot: T([
          {time: V('2014-12-16 13:00')}
          {time: V('2014-12-16 14:00')}
        ])
      })
      }
      {
      name: V('Matt McCutchen')
      Student: U({
        parent: V(I(5))
      })
      }
      {
      name: V('Michael McCutchen')
      Student: U({
        parent: V(I(5))
      })
      }
      {
      name: V('Shachar Itzhaky')
      Student: U({
        parent: V(I(6))
      })
      }
      {
      name: V('Rosemary McCutchen')
      }
      {
      name: V('Yoram Itzhaky')
      }
    ])
    Class: T([
      {
      code: V('6.170')
      name: V('Software Studio')
      Section: T([
        {
        teacher: V(I(0))
        student: V(I(2), I(3))
        }
      ])
      }
      {
      code: V('6.*+~')
      name: V('Alloy')
      Section: T([
        {
        teacher: V(I(0))
        student: V(I(2), I(4))
        }
      ])
      }
      {
      code: V('6.:::')
      name: V('Managed Time')
      Section: T([
        {
        teacher: V(I(1))
        student: V(I(2))
        }
      ])
      }
    ])
    Meeting: T([
      {
      enrollment: V(I(2, 0, 0))
      slot: V(I(1, 0))
      }
      {
      enrollment: V(I(0, 0, 0))
      slot: V(I(0, 1))
      }
      {
      enrollment: V(I(1, 0, 0))
      slot: V(I(0, 2))
      }
      {
      enrollment: V(I(0, 0, 1))
      slot: V(I(0, 3))
      }
      {
      enrollment: V(I(1, 0, 1))
      slot: V(I(0, 0))
      }
    ])
  }

  # Add a super dict representing _unit, though it doesn't get an ID or anything.
  superSchema = {children: sampleSchema}

  scanColumns = (parentId, schema) ->
    schema.children ?= []
    for columnDef in schema.children
      thisId = model.defineColumn(
        parentId,
        columnDef.name,
        # This only works because all of the types in our sample dataset refer to
        # columns that come earlier in preorder.  We can probably live with this
        # until we implement full validation of acyclic type usage.
        model.parseTypeStr(columnDef.type),
        columnDef.cellName,
        null  # formula
      )
      scanColumns(thisId, columnDef)
  scanColumns(rootColumnId, superSchema)

  # Insert cells into columns.
  insertCells = (columnId, cellId, cellData) ->
    for childColumnName, childCells of cellData ? {}
      childColumnId = model.getColumn(columnId).childByName.get(childColumnName)
      for entry in childCells  # No point in making a map just to expand it again.
        [value, childCellData] = entry
        model.writeState({columnId: childColumnId, cellId: cellId}, value, true)
        insertCells(childColumnId, cellIdChild(cellId, value), childCellData)
  insertCells(rootColumnId, rootCellId, sampleData)

  # Add a formula column for testing purposes.
  # XXX parseTypeStr is not really meant to be used for this.
  personNameColumnId = model.parseTypeStr('Person.name')
  model.defineColumn(personNameColumnId, 'nameThis', null, null, ['var', 'this'])
