
@exists = (arr, p) ->
  for x in arr
    if p(x) then return true
  false

@andThen = (x,y) -> x

@zipAll = (arrs) ->
  i = 0
  while @exists arrs, ((arr) -> i < arr.length)
    @andThen (arr[i] for arr in arrs), i=i+1

@reduce = (arr, f) ->
  x = arr[0]
  for y in arr[1..]
    x = f(x,y)
  x

@concatAll = (arrs) -> @reduce arrs, ((x,y) -> x.concat y)
