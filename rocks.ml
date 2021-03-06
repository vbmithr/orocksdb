open Ctypes
open Foreign
open Rocks_common

module Views = Views

exception OperationOnInvalidObject = Rocks_common.OperationOnInvalidObject

module WriteBatch = struct
  module C = CreateConstructors_(struct let name = "writebatch" end)
  include C

  let clear =
    foreign
      "rocksdb_writebatch_clear"
      (t @-> returning void)

  let count =
    foreign
      "rocksdb_writebatch_count"
      (t @-> returning int)

  let put_raw =
    foreign
      "rocksdb_writebatch_put"
      (t @->
       ptr char @-> Views.int_to_size_t @->
       ptr char @-> Views.int_to_size_t @-> returning void)

  let put_raw_string =
    foreign
      "rocksdb_writebatch_put"
      (t @->
       ocaml_string @-> Views.int_to_size_t @->
       ocaml_string @-> Views.int_to_size_t @-> returning void)

  let put_cstruct batch key value =
    let open Cstruct in
    put_raw batch
      (bigarray_start array1 @@ to_bigarray key) key.len
      (bigarray_start array1 @@ to_bigarray value) value.len

  let put ?(key_pos=0) ?key_len ?(value_pos=0) ?value_len batch key value =
    let open Bigarray.Array1 in
    let key_len = match key_len with None -> size_in_bytes key - key_pos | Some len -> len in
    let value_len = match value_len with None -> size_in_bytes value - value_pos | Some len -> len in
    let key = sub key key_pos key_len in
    let value = sub value value_pos value_len in
    put_raw batch (bigarray_start array1 key) key_len (bigarray_start array1 value) value_len

  let put_string ?(key_pos=0) ?key_len ?(value_pos=0) ?value_len batch key value =
    let key_len = match key_len with None -> String.length key - key_pos | Some len -> len in
    let value_len = match value_len with None -> String.length value - value_pos | Some len -> len in
    put_raw_string batch
      (ocaml_string_start key +@ value_pos) value_len
      (ocaml_string_start value +@ key_pos) key_len

  let delete_raw =
    foreign
      "rocksdb_writebatch_delete"
      (t @-> ptr char @-> Views.int_to_size_t @-> returning void)

  let delete_raw_string =
    foreign
      "rocksdb_writebatch_delete"
      (t @-> ocaml_string @-> Views.int_to_size_t @-> returning void)

  let delete_cstruct batch key =
    Cstruct.(delete_raw batch (bigarray_start array1 @@ to_bigarray key) key.len)

  let delete ?(pos=0) ?len batch key =
    let open Bigarray.Array1 in
    let len = match len with None -> size_in_bytes key - pos | Some len -> len in
    delete_raw batch (bigarray_start array1 key) len

  let delete_string ?(pos=0) ?len batch key =
    let len = match len with None -> String.length key - pos | Some len -> len in
    delete_raw_string batch (ocaml_string_start key +@ pos) len
end

module Version = Rocks_version

module rec Iterator : Rocks_intf.ITERATOR with type db := RocksDb.t = struct
  module ReadOptions = Rocks_options.ReadOptions
  type nonrec t = t
  let t = t

  type db
  let db = t

  let get_pointer = get_pointer

  exception InvalidIterator

  let create_no_gc =
    foreign
      "rocksdb_create_iterator"
      (db @-> ReadOptions.t @-> returning t)

  let destroy =
    let inner =
      foreign
        "rocksdb_iter_destroy"
        (t @-> returning void)
    in
    fun t ->
      inner t;
      t.valid <- false

  let create ?opts db =
    let inner opts =
      let t = create_no_gc db opts in
      Gc.finalise destroy t;
      t
    in
    match opts with
    | None -> ReadOptions.with_t inner
    | Some opts -> inner opts

  let with_t ?opts db ~f =
    let inner opts =
      let t = create_no_gc db opts in
      finalize (fun () -> f t) (fun () -> destroy t)
    in
    match opts with
    | None -> ReadOptions.with_t inner
    | Some opts -> inner opts

  let is_valid =
    foreign
      "rocksdb_iter_valid"
      (t @-> returning Views.bool_to_uchar)

  let seek_to_first =
    foreign
      "rocksdb_iter_seek_to_first"
      (t @-> returning void)

  let seek_to_last =
    foreign
      "rocksdb_iter_seek_to_last"
      (t @-> returning void)

  let seek_raw =
    foreign
      "rocksdb_iter_seek"
      (t @-> ptr char @-> Views.int_to_size_t @-> returning void)

  let seek_raw_string =
    foreign
      "rocksdb_iter_seek"
      (t @-> ocaml_string @-> Views.int_to_size_t @-> returning void)

  let seek_cstruct t key =
    Cstruct.(seek_raw t (bigarray_start array1 @@ to_bigarray key) key.len)

  let seek ?(pos=0) ?len t key =
    let open Bigarray.Array1 in
    let len = match len with None -> size_in_bytes key - pos | Some len -> len in
    seek_raw t (bigarray_start array1 key) len

  let seek_string ?(pos=0) ?len t key =
    let len = match len with None -> String.length key - pos | Some len -> len in
    seek_raw_string t (ocaml_string_start key +@ pos) len

  let next =
    foreign
      "rocksdb_iter_next"
      (t @-> returning void)

  let prev =
    foreign
      "rocksdb_iter_prev"
      (t @-> returning void)

  let get_key_raw =
    let inner =
      foreign "rocksdb_iter_key" (t @-> ptr Views.int_to_size_t @-> returning (ptr char))
    in
    fun t size -> if is_valid t then inner t size else raise InvalidIterator

  let get_key t =
    let res_size = allocate Views.int_to_size_t 0 in
    let res = get_key_raw t res_size in
    if (to_voidp res) = null
    then failwith (Printf.sprintf "could not get key, is_valid=%b" (is_valid t))
    else Bigarray.(Array1.sub (bigarray_of_ptr array1 1 char res) 0 (!@ res_size))

  let get_key_cstruct t = get_key t |> Cstruct.of_bigarray

  let get_key_string t =
    let res_size = allocate Views.int_to_size_t 0 in
    let res = get_key_raw t res_size in
    if (to_voidp res) = null
    then failwith (Printf.sprintf "could not get key, is_valid=%b" (is_valid t))
    else string_from_ptr res (!@ res_size)

  let get_value_raw =
    let inner =
      foreign "rocksdb_iter_value" (t @-> ptr Views.int_to_size_t @-> returning (ptr char))
    in
    fun t size -> if is_valid t then inner t size else raise InvalidIterator

  let get_value t =
    let res_size = allocate Views.int_to_size_t 0 in
    let res = get_value_raw t res_size in
    if (to_voidp res) = null
    then failwith (Printf.sprintf "could not get value, is_valid=%b" (is_valid t))
    else Bigarray.(Array1.sub (bigarray_of_ptr array1 1 char res) 0 (!@ res_size))

  let get_value_cstruct t = get_value t |> Cstruct.of_bigarray

  let get_value_string t =
    let res_size = allocate Views.int_to_size_t 0 in
    let res = get_value_raw t res_size in
    if (to_voidp res) = null
    then failwith (Printf.sprintf "could not get value, is_valid=%b" (is_valid t))
    else string_from_ptr res (!@ res_size)

  let get_error_raw =
    foreign
      "rocksdb_iter_get_error"
      (t @-> ptr string_opt @-> returning void)

  let get_error t =
    let err_pointer = allocate string_opt None in
    get_error_raw t err_pointer;
    !@err_pointer

  let fold ?from t ~init ~f =
    (match from with None -> () | Some key -> seek_cstruct t key);
    let rec inner a =
      let res = f ~key:(get_key_cstruct t) ~data:(get_value_cstruct t) a in
      next t;
      if not @@ is_valid t then res else inner res
    in
    inner init

  let fold_right ?from t ~init ~f =
    (match from with None -> () | Some key -> seek_cstruct t key);
    let rec inner a =
      let res = f ~key:(get_key_cstruct t) ~data:(get_value_cstruct t) a in
      prev t;
      if not @@ is_valid t then res else inner res
    in
    inner init

  let iteri ?from t ~f = fold ?from t ~init:() ~f:(fun ~key ~data () -> f ~key ~data)
  let rev_iteri ?from t ~f = fold_right ?from t ~init:() ~f:(fun ~key ~data () -> f ~key ~data)
end

and RocksDb : Rocks_intf.ROCKS with type batch := WriteBatch.t = struct
  module ReadOptions = Rocks_options.ReadOptions
  module WriteOptions = Rocks_options.WriteOptions
  module FlushOptions = Rocks_options.FlushOptions
  module Options = Rocks_options.Options

  type nonrec t = t
  type batch

  let t = t

  let get_pointer = get_pointer

  let returning_error typ = ptr string_opt @-> returning typ

  let with_err_pointer f =
    let err_pointer = allocate string_opt None in
    let res = f err_pointer in
    match !@ err_pointer with
    | None -> res
    | Some err -> failwith err

  let open_db_raw =
    foreign
      "rocksdb_open"
      (Options.t @-> string @-> ptr string_opt @-> returning t)

  let open_db ?opts name =
    match opts with
    | None -> Options.with_t (fun options -> with_err_pointer (open_db_raw options name))
    | Some opts -> with_err_pointer (open_db_raw opts name)

  let close =
    let inner =
      foreign
        "rocksdb_close"
        (t @-> returning void)
    in
    fun t ->
      inner t;
      t.valid <- false

  let with_db ?opts name ~f =
    let db = open_db ?opts name in
    finalize (fun () -> f db) (fun () -> close db)

  let put_raw =
    foreign
      "rocksdb_put"
      (t @-> WriteOptions.t @->
       ptr char @-> Views.int_to_size_t @->
       ptr char @-> Views.int_to_size_t @->
       returning_error void)

  let put_raw_string =
    foreign
      "rocksdb_put"
      (t @-> WriteOptions.t @->
       ocaml_string @-> Views.int_to_size_t @->
       ocaml_string @-> Views.int_to_size_t @->
       returning_error void)

  let put_cstruct ?opts t key value =
    let open Cstruct in
    let inner opts = with_err_pointer begin
        put_raw t opts
          (bigarray_start array1 @@ to_bigarray key) key.len
          (bigarray_start array1 @@ to_bigarray value) value.len
      end
    in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> inner opts

  let put ?(key_pos=0) ?key_len ?(value_pos=0) ?value_len ?opts t key value =
    let open Bigarray.Array1 in
    let key_len = match key_len with None -> size_in_bytes key - key_pos | Some len -> len in
    let value_len = match value_len with None -> size_in_bytes value - value_pos | Some len -> len in
    let key = sub key key_pos key_len in
    let value = sub value value_pos value_len in
    let inner opts = with_err_pointer begin
        put_raw t opts
          (bigarray_start array1 key) key_len
          (bigarray_start array1 value) value_len
      end
    in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> inner opts

  let put_string ?(key_pos=0) ?key_len ?(value_pos=0) ?value_len ?opts t key value =
    let key_len = match key_len with None -> String.length key - key_pos | Some len -> len in
    let value_len = match value_len with None -> String.length value - value_pos | Some len -> len in
    let inner opts = with_err_pointer begin
        put_raw_string t opts
          (ocaml_string_start key +@ key_pos) key_len
          (ocaml_string_start value +@ value_pos) value_len
      end
    in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> inner opts

  let delete_raw =
    foreign
      "rocksdb_delete"
      (t @-> WriteOptions.t @->
       ptr char @-> Views.int_to_size_t @->
       returning_error void)

  let delete_raw_string =
    foreign
      "rocksdb_delete"
      (t @-> WriteOptions.t @->
       ocaml_string @-> Views.int_to_size_t @->
       returning_error void)

  let delete ?(pos=0) ?len ?opts t key =
    let open Bigarray.Array1 in
    let len = match len with None -> size_in_bytes key - pos | Some len -> len in
    let key = sub key pos len in
    let inner opts =
      with_err_pointer (delete_raw t opts (bigarray_start array1 key) len) in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> inner opts

  let delete_cstruct ?opts t key = delete ?opts t @@ Cstruct.to_bigarray key

  let delete_string ?(pos=0) ?len ?opts t key =
    let len = match len with None -> String.length key - pos | Some len -> len in
    let inner opts =
      with_err_pointer (delete_raw_string t opts (ocaml_string_start key +@ pos) len) in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> inner opts

  let write_raw =
    foreign
      "rocksdb_write"
      (t @-> WriteOptions.t @-> WriteBatch.t @->
       returning_error void)

  let write ?opts t wb =
    let inner opts = with_err_pointer (write_raw t opts wb) in
    match opts with
    | None -> WriteOptions.with_t inner
    | Some opts -> with_err_pointer (write_raw t opts wb)

  let get_raw =
    foreign
      "rocksdb_get"
      (t @-> ReadOptions.t @->
       ptr char @-> Views.int_to_size_t @-> ptr Views.int_to_size_t @->
       returning_error (ptr char))

  let get_raw_string =
    foreign
      "rocksdb_get"
      (t @-> ReadOptions.t @->
       ocaml_string @-> Views.int_to_size_t @-> ptr Views.int_to_size_t @->
       returning_error (ptr char))

  let get ?(pos=0) ?len ?opts t key =
    let open Bigarray.Array1 in
    let len = match len with None -> size_in_bytes key - pos | Some len -> len in
    let key = sub key pos len in
    let inner opts =
      let res_size = allocate Views.int_to_size_t 0 in
      let res = with_err_pointer
          (get_raw t opts (bigarray_start array1 key) len res_size)
      in
      if (to_voidp res) = null
      then None
      else begin
        let res' =
          Bigarray.(sub (bigarray_of_ptr array1 1 Bigarray.char res) 0 (!@ res_size))
        in
        Gc.finalise (fun res -> free (to_voidp res)) res;
        Some res'
      end
    in
    match opts with
    | Some opts -> inner opts
    | None -> ReadOptions.with_t inner

  let get_cstruct ?opts t key =
    match get ?opts t @@ Cstruct.to_bigarray key with
    | None -> None
    | Some ba -> Some (Cstruct.of_bigarray ba)

  let get_string ?(pos=0) ?len ?opts t key =
    let len = match len with None -> String.length key - pos | Some len -> len in
    let inner opts =
      let res_size = allocate Views.int_to_size_t 0 in
      let res = with_err_pointer
          (get_raw_string t opts (ocaml_string_start key +@ pos) len res_size)
      in
      if (to_voidp res) = null
      then None
      else begin
        let res' = string_from_ptr res (!@ res_size) in
        Gc.finalise (fun res -> free (to_voidp res)) res;
        Some res'
      end
    in
    match opts with
    | Some opts -> inner opts
    | None -> ReadOptions.with_t inner

  let flush_raw =
      foreign
        "rocksdb_flush"
        (t @-> FlushOptions.t @-> returning_error void)

  let flush ?opts t =
    let inner opts = with_err_pointer (flush_raw t opts) in
    match opts with
    | None -> FlushOptions.with_t inner
    | Some opts -> inner opts

  let fold ?opts ?from t ~init ~f = Iterator.with_t ?opts t ~f:(Iterator.fold_right ?from ~init ~f)
  let fold_right ?opts ?from t ~init ~f = Iterator.with_t ?opts t ~f:(Iterator.fold_right ?from ~init ~f)
  let iteri ?opts ?from t ~f = Iterator.with_t ?opts t ~f:(Iterator.iteri ?from ~f)
  let rev_iteri ?opts ?from t ~f = Iterator.with_t ?opts t ~f:(Iterator.rev_iteri ?from ~f)
end

include RocksDb
