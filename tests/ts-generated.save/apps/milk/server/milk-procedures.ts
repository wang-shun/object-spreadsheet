namespace Objsheets {

  RelsheetsServer.procedures("milk", {
    supply: {
      params: [["me", "Team"]],
      body: "$Gauge.reading := {l: $Gauge.Level | l.name = \"Full\"}\nme.quota := me.quota - 2\nif (me.quota <= 0) {\n  me.lastTime := d\"now\" \n  $Team.quota := 4      # reset all quotas\n  let m = new $Message\n  m.`to` := {c: $Team | c.isNext}\n  m.subject := \"Heads Up: You Are Next\"\n}"  // reset all quotas
    },
    request: {
      params: [["level", "Gauge:Level"]],
      body: "$Gauge.reading := level\nlet m = new $Message\nm.`to` := {c: $Team | c.isNext}\nm.subject := \"Milk Level Alert\" "
    },
    // We can change the semantics of the button request here as desired.
    dashButtonRequest: {
      params: [],
      body: "$Gauge.reading := {l: $Gauge.Level | l.name = \"Empty\"}\nlet m = new $Message\nm.`to` := {c: $Team | c.isNext}\nm.subject := \"Milk Level Alert\" "
    }
  });

}
