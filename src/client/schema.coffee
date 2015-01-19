if Meteor.isClient
  Template.Schema.helpers
    columns: -> Columns.find({}, {sort: {parent: 1}})
    short: (s) -> if s? then s[...4]
    human: (type) ->
      if type?
        if /^_/.exec type
          type
        else
          col = Columns.findOne({_id: type})
          if col?
            col.cellName ? col.name
          else
            "#{type[...4]}..."
      else
        "?"
