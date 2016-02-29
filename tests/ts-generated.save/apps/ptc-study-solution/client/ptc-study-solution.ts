namespace Objsheets {

  Router.route("/:sheet/apps/ptc-study-solution", function() {
    this.render("PTC_study_solution_login", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["PTC_study_solution_login"].created = function() {
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

  Router.route("/:sheet/apps/ptc-study-solution/:familyPage", function() {
    this.render("PTC_study_solution_FamilyPage", {
      data: {
        sheet: this.params.sheet,
        familyPage: JSON.parse(this.params.familyPage)
      }
    });
  });

  Template["PTC_study_solution_FamilyPage"].created = function() {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "ptc-study-solution");
  };

  Template["PTC_study_solution_FamilyPage"].helpers({
    FamilyPage: function() {
      return RelsheetsClient.readSubtree("FamilyPage", this.familyPage);
    },
    formatDate: (d) => valueToTextIgnoreErrors("date", d)
  });

  function blur(jbutton) {
    jbutton.width(jbutton.width());
    jbutton.text("∙ ∙ ∙");
  }

  Template["PTC_study_solution_FamilyPage"].events({
    "click .schedule": function(ev) {
      blur($(ev.target));
      RelsheetsClient.call("parentScheduleMeeting", {
        block: this
      }, (error, result) => {
        $(ev.target).text("Schedule");
      });
    },
    "click .cancel": function(ev) {
      blur($(ev.target));
      RelsheetsClient.call("parentCancelMeeting", {
        block: this
      }, (error, result) => {
        $(ev.target).text("Cancel");
      });
    }
  });

}
