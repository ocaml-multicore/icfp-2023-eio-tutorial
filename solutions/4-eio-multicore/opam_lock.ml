let v = Mutex.create ()

let use fn =
  Mutex.lock v;
  match fn () with
  | x ->
    Mutex.unlock v;
    x
  | exception ex ->
    Mutex.unlock v;
    raise ex
