namespace Objsheets {

  export class HtmlOption {
    constructor(public value: fixmeAny, public label: fixmeAny) {}
  }

  export class HtmlOptgroup {
    constructor(public label: fixmeAny, public members: fixmeAny) {}
  }

  export class HtmlSelect {
    // @items: array of HtmlOption and/or HtmlOptgroup

    constructor(public items: fixmeAny, public currentValue: fixmeAny) {}
  }

  // Since we aren't generating the <select> element itself, the event goes to the
  // parent template and we don't have to deal with the nonsense of making a
  // reference between the templates.  Yay!

  Template["html_select_content"].helpers({
    currentValueFound: function() {
      for (let item of this.items) {
        if (item instanceof HtmlOptgroup) {
          for (let subitem of item.members) {
            if (this.currentValue === subitem.value) {
              return true;
            }
          }
        } else {
          if (this.currentValue === item.value) {
            return true;
          }
        }
      }
      return false;
    },
    isOptgroup: function() {
      return this instanceof HtmlOptgroup;
    },
    isSelected: function() {
      let parent = <fixmeAny>Template.parentData(1);
      if (parent instanceof HtmlOptgroup) {
        parent = Template.parentData(2);
      }
      return this.value === parent.currentValue;
    }
  });

  export function selectOptionWithValue(template: fixmeAny, selectSelector: fixmeAny, value: fixmeAny) {
    template.find(`${selectSelector} option[value=${value}]`).selected = true;
  }

  export function getValueOfSelectedOption(template: fixmeAny, selectSelector: fixmeAny) {
    return template.$(selectSelector).val();
  }

}
