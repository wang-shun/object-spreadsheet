
if Meteor.isClient
  Router.route "/005q/apps", -> @render "DoubleOhFiveQueue", data: {sheet: '005q'}

  Template.DoubleOhFiveQueue.created = ->
    sheet = @data?.sheet
    Tablespace.default = Tablespace.get sheet

  Template.DoubleOhFiveQueue.helpers
    root: ->
      t = View.rootLayout()
      readObj(t, [])
      