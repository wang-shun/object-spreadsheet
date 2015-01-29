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
        type: 'Person:Teacher'
        # TODO: Required, singleton
        }
        {
        # There's some doubt in my mind whether the enrollment should be thought
        # of as belonging to the section.  We might want to associate other data
        # (e.g., grades) with it that is as important to the student as it is to
        # the section.  But for now, this is useful as an example of having both
        # a name and a cellName. ~ Matt
        name: 'student'
        type: 'Person:Student'
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
      type: 'Class:Section:Enrollment'
      # TODO: Required, singleton, unique
      }
      {
      name: 'slot'
      type: 'Person:Teacher:Slot'
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
  U = (cell) -> [['X', cell]]

  # Type _token: successive integer tokens for now.
  T = (cellList) -> ([i.toString(), cell] for cell, i in cellList)

  I = () ->
    for x in arguments
      if typeof x == 'number' then x.toString() else x

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
        teacher: V(I(0, 'X'))
        student: V(I(2, 'X'), I(3, 'X'))
        }
      ])
      }
      {
      code: V('6.*+~')
      name: V('Alloy')
      Section: T([
        {
        teacher: V(I(0, 'X'))
        student: V(I(2, 'X'), I(4, 'X'))
        }
      ])
      }
      {
      code: V('6.:::')
      name: V('Managed Time')
      Section: T([
        {
        teacher: V(I(1, 'X'))
        student: V(I(2, 'X'))
        }
      ])
      }
    ])
    Meeting: T([
      {
      enrollment: V(I(2, 0, I(2, 'X')))
      slot: V(I(1, 'X', 0))
      }
      {
      enrollment: V(I(0, 0, I(2, 'X')))
      slot: V(I(0, 'X', 1))
      }
      {
      enrollment: V(I(1, 0, I(2, 'X')))
      slot: V(I(0, 'X', 2))
      }
      {
      enrollment: V(I(0, 0, I(3, 'X')))
      slot: V(I(0, 'X', 3))
      }
      {
      enrollment: V(I(1, 0, I(4, 'X')))
      slot: V(I(0, 'X', 0))
      }
    ])
  }

  # Add a super dict representing _unit, though it doesn't get an ID or anything.
  superSchema = {children: sampleSchema}

  # Delete all existing columns!!
  new Model().drop()
  Views.remove {}

  model = new Model()
  @getColumn = (id) -> model.getColumn(id)

  scanColumns = (parentId, schema) ->
    schema.children ?= []
    for columnDef, i in schema.children
      thisId = model.defineColumn(
        parentId, i,
        columnDef.name,
        # This only works because all of the types in our sample dataset refer to
        # columns that come earlier in preorder.  We can probably live with this
        # until we implement full validation of acyclic type usage.
        parseTypeStr(columnDef.type),
        columnDef.cellName,
        null  # formula
      )
      scanColumns(thisId, columnDef)
  scanColumns(rootColumnId, superSchema)

  # Insert cells into columns.
  insertCells = (columnId, cellId, cellData) ->
    for childColumnName, childCells of cellData ? {}
      childColumnId = model.getColumn(columnId).childByName.get(childColumnName)
      childColumn = new ColumnBinRel(childColumnId)
      for entry in childCells  # No point in making a map just to expand it again.
        [value, childCellData] = entry
        childColumn.add(cellId, value)
        insertCells(childColumnId, cellIdChild(cellId, value), childCellData)
  insertCells(rootColumnId, rootCellId, sampleData)

  # Add some formula columns.
  # NOTE: It can be subtle to remember what "this" refers to in a formula, so I
  # anticipate encouraging users of the concrete syntax to instead use the
  # cellName of the parent column, which generates a trivial call to "up".
  # The example formulas reflect this convention.
  model.defineColumn(parseColumnRef("Person:Student:parent"),
                     0, "parent's name", null, null,
                     ["down",["up",["var","this"],"Person:Student:parent",true],"Person:name",true])
  model.defineColumn(parseColumnRef("Person:Teacher:Slot"),
                     1, "scheduled meeting", null, null,
                     ["filter",["down",["lit","_root",[[]]],"Meeting",false],["m",["=",["down",["var","m"],"Meeting:slot",true],["up",["var","this"],"Person:Teacher:Slot",false]]]])

  model.defineColumn(parseColumnRef("Person:Teacher:Slot:scheduled meeting"),
                     0, "discussed", null, null,
                     ["up",["down",["_"],"Meeting:enrollment",true],"Class:Section:student",true])
  model.defineColumn(parseColumnRef("Person:Teacher:Slot:scheduled meeting:discussed"),
                     0, "student's name", null, null,
                     ["down",["up",["_"],"Person",false],"Person:name",true])

  model.defineColumn(parseColumnRef("Person"),
                     1, "children", null, null,
                     # {c in Person | this in c.parent}
                     ["filter",["down",["::"],"Person",false],["c",["in",["var","this"],["down",["var","c"],"Person:Student:parent",true]]]],
                     {view: '1'})
  model.defineColumn(parseColumnRef("Person:children"),
                     0, "child's name", null, null,
                     ["down",["_"],"Person:name",true],
                     {view: '1'})

  model.evaluateAllFlat()  # prepare dependencies

  # Create a view
  T = -> new Tree arguments...

  view1 =
    _id: '1'
    layout: T('_root', [T('Person', [T('Person:name'),
              T('Person:children', [T("Person:children:child's name")])])])
            .map parseColumnRef

  Views.upsert(view1._id, view1)

  model
