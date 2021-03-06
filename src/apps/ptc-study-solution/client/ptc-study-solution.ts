namespace Objsheets {

  Router.route("/:sheet/apps/ptc-study-solution", function(this: fixmeAny) {
    this.render("PTC_study_solution_login", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["PTC_study_solution_login"].created = function(this: fixmeAny) {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null);  // no procedures
  };

  Template["PTC_study_solution_login"].helpers({
    root: () => {
      try {
        return RelsheetsClient.readObj(T(rootColumnId, [T(parseObjectTypeRef("FamilyPage"), [T(parseColumnRef("FamilyPage:studentName")[0])])]));
      } catch (e) {
        // Saw some cases of not ready.  XXX: Distinguish from real errors.
        return {};
      }
    },
    JSON_stringify: JSON.stringify
  });

  Router.route("/:sheet/apps/ptc-study-solution/:familyPage", function(this: fixmeAny) {
    this.render("PTC_study_solution_FamilyPage", {
      data: {
        sheet: this.params.sheet,
        familyPage: JSON.parse(this.params.familyPage)
      }
    });
  });

  Template["PTC_study_solution_FamilyPage"].created = function(this: fixmeAny) {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "ptc-study-solution");
  };

  Template["PTC_study_solution_FamilyPage"].helpers({
    FamilyPage: function(this: fixmeAny) {
      return RelsheetsClient.readSubtree("FamilyPage", this.familyPage);
    },
    formatDate: (d: fixmeAny) => valueToTextIgnoreErrors("date", d)
  });

  function blur(jbutton: fixmeAny) {
    jbutton.width(jbutton.width());
    jbutton.text("∙ ∙ ∙");
  }

  Template["PTC_study_solution_FamilyPage"].events({
    "click .schedule": function(this: fixmeAny, ev: fixmeAny) {
      blur($(ev.target));
      RelsheetsClient.call("parentScheduleMeeting", {
        block: this
      }, (error: fixmeAny, result: fixmeAny) => {
        $(ev.target).text("Schedule");
      });
    },
    "click .cancel": function(this: fixmeAny, ev: fixmeAny) {
      blur($(ev.target));
      RelsheetsClient.call("parentCancelMeeting", {
        block: this
      }, (error: fixmeAny, result: fixmeAny) => {
        $(ev.target).text("Cancel");
      });
    }
  });

}
