class HtmlOption
  constructor: (@value, @label) ->

class HtmlOptgroup
  constructor: (@label, @members) ->

class HtmlSelect
  # @items: array of HtmlOption and/or HtmlOptgroup
  constructor: (@items, @currentValue) ->

exported {HtmlOption, HtmlOptgroup, HtmlSelect}

# Since we aren't generating the <select> element itself, the event goes to the
# parent template and we don't have to deal with the nonsense of making a
# reference between the templates.  Yay!

Template.html_select_content.helpers({
  currentValueFound: ->
    for item in @items
      if item instanceof HtmlOptgroup
        for subitem in item.members
          return true if @currentValue == subitem.value
      else
        return true if @currentValue == item.value
    return false
  isOptgroup: -> this instanceof HtmlOptgroup
  isSelected: ->
    parent = Template.parentData(1)
    if parent instanceof HtmlOptgroup
      parent = Template.parentData(2)
    @value == parent.currentValue
})

@selectOptionWithValue = (template, selectSelector, value) ->
  template.find("#{selectSelector} option[value=#{value}]").selected = true

@getValueOfSelectedOption = (template, selectSelector) ->
  template.$(selectSelector).val()
