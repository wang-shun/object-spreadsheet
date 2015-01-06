Person = [
  [0, "Daniel Jackson"]
  [1, "Jonathan Edwards"]
  [2, "Hefty"]
  [3, "Brainy"]
  [4, "Clumsy"]
  [5, "Greedy"]
  [6, "Jokey"]
  [7, "Chef"]
  [8, "Vanity"]
]
  
  
$ () ->
  x = document.getElementById("Person")
  new Handsontable x,
    data: Person
    colHeaders: ["ID", "Name", ""]
