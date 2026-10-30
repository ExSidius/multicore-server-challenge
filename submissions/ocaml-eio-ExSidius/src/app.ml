(* The 19 Conduit endpoints, running the reference SQL from SPEC.md. *)
open Http

exception Fail of int * string

let fail status msg = raise (Fail (status, msg))

type t = { pool : Pg.pool; secret : string }

(* ---------- SQL ---------- *)

(* Postgres is the bottleneck, so each endpoint makes one round trip where it can: a lookup and the statement that
   depends on it are one statement, and so is a page with its count. Results match the reference SQL in SPEC.md. *)

(* Two plan details matter most. Tag names come from a primary-key probe per tag: a plain join is planned as a hash
   join that scans all of tags for every article. And pages are chosen by id first, from an index alone: with
   LIMIT/OFFSET on the outer query, Postgres computes every subquery for the rows OFFSET then throws away. *)

let article_rest ~favorites_count ~favorited =
  {|ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       |} ^ favorites_count ^ {| AS favorites_count,
       |} ^ favorited ^ {| AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id|}

let stored_count = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
let stored_favorited = "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)"
let tag_fav_follow = article_rest ~favorites_count:stored_count ~favorited:stored_favorited
let list_columns = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
let full_columns = "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
let list_select = list_columns ^ tag_fav_follow
let full_select = full_columns ^ tag_fav_follow
let s = Pg.stmt

(* One row with total set even for an empty page; then the page's columns are NULL. *)
let with_count ~count list =
  s ("SELECT p.*, c.total FROM (" ^ count ^ ") c(total) LEFT JOIN LATERAL (" ^ list ^ ") p ON true ORDER BY p.id DESC")

let list_total_column = 13

let list_all =
  with_count ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s" (list_select ^ " WHERE a.id IN (SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_tag =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_author =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_favorited =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_feed =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let article_by_slug = s (full_select ^ " WHERE a.slug = $2")
let article_by_id = s (full_select ^ " WHERE a.id = $2")

(* A statement's reads don't see its own writes, so the count is adjusted by what the write actually changed. *)
let favorite_article =
  s ("WITH w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM articles WHERE slug = $2 ON CONFLICT DO NOTHING RETURNING 1) "
    ^ full_columns
    ^ article_rest ~favorites_count:(stored_count ^ " + (SELECT count(*) FROM w)") ~favorited:"true"
    ^ " WHERE a.slug = $2")

let unfavorite_article =
  s ("WITH w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM articles WHERE slug = $2) RETURNING 1) "
    ^ full_columns
    ^ article_rest ~favorites_count:(stored_count ^ " - (SELECT count(*) FROM w)") ~favorited:"false"
    ^ " WHERE a.slug = $2")

(* Slugs are computed by the app ($5), which spares Postgres the regular expression. *)
let insert_article =
  s "INSERT INTO articles (id, slug, author_id, title, description, body)\nSELECT n.id, $5::text || '-' || n.id, $1, $2, $3, $4\n  FROM (SELECT nextval('articles_id_seq') AS id) n\nRETURNING id"

let insert_tags = s "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
let insert_article_tags = s "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

let update_article =
  s "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),\n       slug = CASE WHEN $5::text IS NULL THEN slug ELSE $5::text || '-' || id END,\n       updated_at = now()\n WHERE id = $1"

let delete_article = s "DELETE FROM articles WHERE id = $1"
let article_id_author = s "SELECT id, author_id FROM articles WHERE slug = $1"
let insert_user = s "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)\nRETURNING id, username, email, bio, image"
let user_by_email = s "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
let user_by_id = s "SELECT id, username, email, bio, image FROM users WHERE id = $1"

let update_user =
  s "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),\n                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)\n WHERE id = $1\nRETURNING id, username, email, bio, image"

let profile_by_username =
  s "SELECT u.id, u.username, u.bio, u.image,\n       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following\n  FROM users u WHERE u.username = $2"

let follow_user =
  s "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n     w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)\nSELECT username, bio, image FROM u"

let unfollow_user =
  s "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n     w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))\nSELECT username, bio, image FROM u"

(* No row: no such article. One row with a NULL id: an article without comments. *)
let list_comments =
  s "SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following\n  FROM articles a LEFT JOIN LATERAL (\n    SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,\n           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following\n      FROM comments c JOIN users u ON u.id = c.author_id\n     WHERE c.article_id = a.id\n     ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\n WHERE a.slug = $2\n ORDER BY c.created_at DESC, c.id DESC"

let insert_comment =
  s "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2\n           RETURNING id, body, created_at, updated_at, author_id)\nSELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image\n  FROM c JOIN users u ON u.id = c.author_id"

let comment_author = s "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id\n WHERE c.id = $1 AND a.slug = $2"
let delete_comment = s "DELETE FROM comments WHERE id = $1"
let all_tags = s "SELECT name FROM tags ORDER BY name"

(* Byte-identical to trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g'))): every byte of a
   multi-byte character is outside the class, so working on bytes gives the same result. *)
let slugify x =
  let b = Buffer.create (String.length x) in
  let pending = ref false in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' | 'A' .. 'Z' ->
          if !pending && Buffer.length b > 0 then Buffer.add_char b '-';
          pending := false;
          Buffer.add_char b (Char.lowercase_ascii c)
      | _ -> pending := true)
    x;
  Buffer.contents b

(* ---------- JSON: types derive their (de)serializers ---------- *)

module Req = struct
  type user_fields = {
    username : string option; [@default None]
    email : string option; [@default None]
    password : string option; [@default None]
    bio : string option; [@default None]
    image : string option; [@default None]
  }
  [@@deriving of_yojson { strict = false }]

  type user = { user : user_fields } [@@deriving of_yojson { strict = false }]

  type article_fields = {
    title : string option; [@default None]
    description : string option; [@default None]
    body : string option; [@default None]
    tagList : string list option; [@default None]
  }
  [@@deriving of_yojson { strict = false }]

  type article = { article : article_fields } [@@deriving of_yojson { strict = false }]
  type comment_fields = { body : string option [@default None] } [@@deriving of_yojson { strict = false }]
  type comment = { comment : comment_fields } [@@deriving of_yojson { strict = false }]
end

module Resp = struct
  type user_fields = {
    email : string;
    token : string;
    username : string;
    bio : string option;
    image : string option;
  }
  [@@deriving to_yojson]

  type user = { user : user_fields } [@@deriving to_yojson]

  type profile_fields = { username : string; bio : string option; image : string option; following : bool }
  [@@deriving to_yojson]

  type profile = { profile : profile_fields } [@@deriving to_yojson]

  type article_fields = {
    slug : string;
    title : string;
    description : string;
    body : string option; [@default None] (* omitted from lists *)
    tagList : string list;
    createdAt : string;
    updatedAt : string;
    favorited : bool;
    favoritesCount : int;
    author : profile_fields;
  }
  [@@deriving to_yojson]

  type article = { article : article_fields } [@@deriving to_yojson]
  type articles = { articles : article_fields list; articlesCount : int } [@@deriving to_yojson]

  type comment_fields = {
    id : int;
    createdAt : string;
    updatedAt : string;
    body : string;
    author : profile_fields;
  }
  [@@deriving to_yojson]

  type comment = { comment : comment_fields } [@@deriving to_yojson]
  type comments = { comments : comment_fields list } [@@deriving to_yojson]
  type tags = { tags : string list } [@@deriving to_yojson]
  type error_fields = { body : string list } [@@deriving to_yojson]
  type error = { errors : error_fields } [@@deriving to_yojson]
end

let respond status json = { status; body = Yojson.Safe.to_string json }
let error_body msg = Yojson.Safe.to_string (Resp.error_to_yojson { errors = { body = [ msg ] } })

(* Postgres timestamps are microseconds since 2000-01-01 UTC. Prints RFC 3339 with truncated milliseconds. *)
let timestamp r i =
  let ms = Int64.to_int (Pg.timestamp r i) in
  let ms = (if ms >= 0 then ms / 1000 else ((ms + 1) / 1000) - 1) + 946684800000 in
  let secs = ms / 1000 in
  let days = secs / 86400 and sod = secs mod 86400 in
  (* civil_from_days (Howard Hinnant) *)
  let z = days + 719468 in
  let era = z / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = yoe + (era * 400) + if m <= 2 then 1 else 0 in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" y m d (sod / 3600) (sod / 60 mod 60) (sod mod 60) (ms mod 1000)

(* Columns as in list_select / full_select; the full form has the body at index 4. *)
let article_of_row ~full (r : Pg.row) : Resp.article_fields =
  let o = if full then 1 else 0 in
  {
    slug = Pg.get r 1;
    title = Pg.get r 2;
    description = Pg.get r 3;
    body = (if full then Some (Pg.get r 4) else None);
    tagList = Pg.text_array r (6 + o);
    createdAt = timestamp r (4 + o);
    updatedAt = timestamp r (5 + o);
    favorited = Pg.bool r (8 + o);
    favoritesCount = Pg.int r (7 + o);
    author =
      { username = Pg.get r (9 + o); bio = r.(10 + o); image = r.(11 + o); following = Pg.bool r (12 + o) };
  }

let comment_of_row (r : Pg.row) ~following : Resp.comment_fields =
  {
    id = Pg.int r 0;
    createdAt = timestamp r 2;
    updatedAt = timestamp r 3;
    body = Pg.get r 1;
    author = { username = Pg.get r 4; bio = r.(5); image = r.(6); following };
  }

(* ---------- request helpers ---------- *)

let i n = Some (string_of_int n)
let t v = Some v

type viewer = { id : int; token : string option }

let anonymous = { id = 0; token = None }

let authenticate app (req : request) =
  match req.authorization with
  | None -> None
  | Some h ->
      if String.length h > 6 && String.sub h 0 6 = "Token " then begin
        let token = String.sub h 6 (String.length h - 6) in
        match Jwt.verify ~secret:app.secret token with
        | Some id -> Some { id; token = Some token }
        | None -> fail 401 "unauthorized"
      end
      else fail 401 "unauthorized"

let required app req = match authenticate app req with Some v -> v | None -> fail 401 "unauthorized"
let optional app req = match authenticate app req with Some v -> v | None -> anonymous
let current_token v = Option.value v.token ~default:""

let parse_uint v =
  if v <> "" && String.for_all (fun c -> c >= '0' && c <= '9') v then Int64.of_string_opt v else None

let limit_offset params =
  let bad () = fail 422 "limit must be 1-100 and offset >= 0" in
  let limit =
    match List.assoc_opt "limit" params with
    | None -> "20"
    | Some v -> (
        match parse_uint v with
        | Some n when n >= 1L && n <= 100L -> Int64.to_string n
        | _ -> bad ())
  in
  let offset =
    match List.assoc_opt "offset" params with
    | None -> "0"
    | Some v -> ( match parse_uint v with Some n -> Int64.to_string n | None -> bad ())
  in
  (limit, offset)

let parse_body of_yojson (req : request) =
  match of_yojson (Yojson.Safe.from_string req.body) with
  | Ok v -> v
  | Error _ | (exception Yojson.Json_error _) -> fail 422 "invalid body"

let non_empty k = function
  | Some "" -> fail 422 (k ^ " must not be empty")
  | v -> v

let required_field k v = match non_empty k v with Some v -> v | None -> fail 422 (k ^ " is required")

let unique_violation f =
  try f () with Pg.Error { code = "23505"; _ } -> fail 422 "username or email is already taken"

(* ---------- users ---------- *)

let user_response app status (r : Pg.row) token =
  let token = match token with Some v -> v | None -> Jwt.sign ~secret:app.secret (Pg.int r 0) in
  respond status
    (Resp.user_to_yojson
       { user = { email = Pg.get r 2; token; username = Pg.get r 1; bio = r.(3); image = r.(4) } })

let hash_password password =
  match Bcrypt.hash password with Some h -> h | None -> fail 422 "password can't be used"

let register app req =
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let username = required_field "username" m.username in
  let email = required_field "email" m.email in
  let password = required_field "password" m.password in
  let hash = hash_password password in
  let row =
    unique_violation (fun () ->
        Pg.with_conn app.pool (fun c -> Pg.exec_one c insert_user [| t username; t email; t hash |]))
  in
  user_response app 201 (Option.get row) None

let login app req =
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let email = required_field "email" m.email in
  let password = required_field "password" m.password in
  let row = Pg.with_conn app.pool (fun c -> Pg.exec_one c user_by_email [| t email |]) in
  match row with
  | Some r when Bcrypt.verify ~password ~hash:(Pg.get r 5) -> user_response app 200 r None
  | _ -> fail 401 "invalid email or password"

let current_user app req =
  let v = required app req in
  match Pg.with_conn app.pool (fun c -> Pg.exec_one c user_by_id [| i v.id |]) with
  | Some r -> user_response app 200 r (Some (current_token v))
  | None -> fail 401 "unauthorized"

let update_user_h app req =
  let v = required app req in
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let email = non_empty "email" m.email in
  let username = non_empty "username" m.username in
  let password = non_empty "password" m.password in
  let hash = Option.map hash_password password in
  let row =
    unique_violation (fun () ->
        Pg.with_conn app.pool (fun c ->
            Pg.exec_one c update_user [| i v.id; email; username; hash; m.bio; m.image |]))
  in
  match row with
  | Some r -> user_response app 200 r (Some (current_token v))
  | None -> fail 401 "unauthorized"

(* ---------- profiles ---------- *)

let profile_response profile = respond 200 (Resp.profile_to_yojson { profile })

let get_profile app req username =
  let v = optional app req in
  match Pg.with_conn app.pool (fun c -> Pg.exec_one c profile_by_username [| i v.id; t username |]) with
  | Some r ->
      profile_response { username = Pg.get r 1; bio = r.(2); image = r.(3); following = Pg.bool r 4 }
  | None -> fail 404 "profile not found"

let follow app req username ~on =
  let v = required app req in
  let stmt = if on then follow_user else unfollow_user in
  match Pg.with_conn app.pool (fun c -> Pg.exec_one c stmt [| i v.id; t username |]) with
  | None -> fail 404 "profile not found"
  | Some r -> profile_response { username = Pg.get r 0; bio = r.(1); image = r.(2); following = on }

(* ---------- articles ---------- *)

let write_list c list params =
  let rows = Pg.exec c list params in
  let articlesCount = match rows with r :: _ -> Pg.int r list_total_column | [] -> 0 in
  let page = List.filter (fun (r : Pg.row) -> r.(0) <> None) rows in
  respond 200 (Resp.articles_to_yojson { articles = List.map (article_of_row ~full:false) page; articlesCount })

let non_empty_param params k =
  match List.assoc_opt k params with Some "" | None -> None | some -> some

let list_articles app (req : request) =
  let v = optional app req in
  let params = query_params req.query in
  let limit, offset = limit_offset params in
  let base = [| i v.id; t limit; t offset |] in
  let filtered list value =
    Pg.with_conn app.pool (fun c -> write_list c list (Array.append base [| t value |]))
  in
  match (non_empty_param params "tag", non_empty_param params "author", non_empty_param params "favorited") with
  | Some tag, _, _ -> filtered list_tag tag
  | None, Some author, _ -> filtered list_author author
  | None, None, Some user -> filtered list_favorited user
  | None, None, None -> Pg.with_conn app.pool (fun c -> write_list c list_all base)

let feed app (req : request) =
  let v = required app req in
  let limit, offset = limit_offset (query_params req.query) in
  Pg.with_conn app.pool (fun c -> write_list c list_feed [| i v.id; t limit; t offset |])

let full_article c status stmt viewer key =
  match Pg.exec_one c stmt [| i viewer; key |] with
  | Some r -> respond status (Resp.article_to_yojson { article = article_of_row ~full:true r })
  | None -> fail 404 "article not found"

let get_article app req slug =
  let v = optional app req in
  Pg.with_conn app.pool (fun c -> full_article c 200 article_by_slug v.id (t slug))

let create_article app req =
  let v = required app req in
  let { Req.article = m } = parse_body Req.article_of_yojson req in
  let title = required_field "title" m.title in
  let description = required_field "description" m.description in
  let body = required_field "body" m.body in
  let tags = Option.value m.tagList ~default:[] in
  if List.mem "" tags then fail 422 "tagList must be an array of non-empty strings";
  Pg.with_conn app.pool (fun c ->
      let id =
        Pg.with_tx c (fun () ->
            let r = Option.get (Pg.exec_one c insert_article [| i v.id; t title; t description; t body; t (slugify title) |]) in
            let id = Pg.int r 0 in
            if tags <> [] then begin
              let lit = t (Pg.text_array_literal tags) in
              ignore (Pg.exec c insert_tags [| lit |]);
              ignore (Pg.exec c insert_article_tags [| i id; lit |])
            end;
            id)
      in
      full_article c 201 article_by_id v.id (i id))

let own_article c slug viewer =
  match Pg.exec_one c article_id_author [| t slug |] with
  | None -> fail 404 "article not found"
  | Some r ->
      if Pg.int r 1 <> viewer then fail 403 "not the author";
      Pg.int r 0

let update_article_h app req slug =
  let v = required app req in
  let { Req.article = m } = parse_body Req.article_of_yojson req in
  let title = non_empty "title" m.title in
  let description = non_empty "description" m.description in
  let body = non_empty "body" m.body in
  Pg.with_conn app.pool (fun c ->
      let id = own_article c slug v.id in
      ignore (Pg.exec c update_article [| i id; title; description; body; Option.map slugify title |]);
      full_article c 200 article_by_id v.id (i id))

let no_content = { status = 204; body = "" }

let delete_article_h app req slug =
  let v = required app req in
  Pg.with_conn app.pool (fun c ->
      let id = own_article c slug v.id in
      ignore (Pg.exec c delete_article [| i id |]);
      no_content)

let favorite app req slug ~on =
  let v = required app req in
  let stmt = if on then favorite_article else unfavorite_article in
  Pg.with_conn app.pool (fun c -> full_article c 200 stmt v.id (t slug))

(* ---------- comments ---------- *)

let get_comments app req slug =
  let v = optional app req in
  match Pg.with_conn app.pool (fun c -> Pg.exec c list_comments [| i v.id; t slug |]) with
  | [] -> fail 404 "article not found"
  | rows ->
      let rows = List.filter (fun (r : Pg.row) -> r.(0) <> None) rows in
      respond 200
        (Resp.comments_to_yojson
           { comments = List.map (fun r -> comment_of_row r ~following:(Pg.bool r 7)) rows })

let create_comment app req slug =
  let v = required app req in
  let { Req.comment = m } = parse_body Req.comment_of_yojson req in
  let body = required_field "body" m.body in
  match Pg.with_conn app.pool (fun c -> Pg.exec_one c insert_comment [| i v.id; t slug; t body |]) with
  | None -> fail 404 "article not found"
  | Some r -> respond 201 (Resp.comment_to_yojson { comment = comment_of_row r ~following:false })

let delete_comment_h app req slug raw_id =
  let v = required app req in
  match parse_uint raw_id with
  | None -> fail 404 "comment not found"
  | Some id ->
      let id = t (Int64.to_string id) in
      Pg.with_conn app.pool (fun c ->
          match Pg.exec_one c comment_author [| id; t slug |] with
          | None -> fail 404 "comment not found"
          | Some r ->
              if Pg.int r 0 <> v.id then fail 403 "not the author";
              ignore (Pg.exec c delete_comment [| id |]);
              no_content)

let tags app =
  let rows = Pg.with_conn app.pool (fun c -> Pg.exec c all_tags [||]) in
  respond 200 (Resp.tags_to_yojson { tags = List.map (fun r -> Pg.get r 0) rows })

(* ---------- routing ---------- *)

let route app (req : request) =
  let seg = decode ~plus:false in
  match (req.meth, String.split_on_char '/' req.path) with
  | "GET", [ ""; "api"; "tags" ] -> tags app
  | "POST", [ ""; "api"; "users" ] -> register app req
  | "POST", [ ""; "api"; "users"; "login" ] -> login app req
  | "GET", [ ""; "api"; "user" ] -> current_user app req
  | "PUT", [ ""; "api"; "user" ] -> update_user_h app req
  | "GET", [ ""; "api"; "profiles"; u ] -> get_profile app req (seg u)
  | "POST", [ ""; "api"; "profiles"; u; "follow" ] -> follow app req (seg u) ~on:true
  | "DELETE", [ ""; "api"; "profiles"; u; "follow" ] -> follow app req (seg u) ~on:false
  | "GET", [ ""; "api"; "articles" ] -> list_articles app req
  | "POST", [ ""; "api"; "articles" ] -> create_article app req
  | "GET", [ ""; "api"; "articles"; "feed" ] -> feed app req
  | "GET", [ ""; "api"; "articles"; x ] -> get_article app req (seg x)
  | "PUT", [ ""; "api"; "articles"; x ] -> update_article_h app req (seg x)
  | "DELETE", [ ""; "api"; "articles"; x ] -> delete_article_h app req (seg x)
  | "POST", [ ""; "api"; "articles"; x; "favorite" ] -> favorite app req (seg x) ~on:true
  | "DELETE", [ ""; "api"; "articles"; x; "favorite" ] -> favorite app req (seg x) ~on:false
  | "GET", [ ""; "api"; "articles"; x; "comments" ] -> get_comments app req (seg x)
  | "POST", [ ""; "api"; "articles"; x; "comments" ] -> create_comment app req (seg x)
  | "DELETE", [ ""; "api"; "articles"; x; "comments"; id ] -> delete_comment_h app req (seg x) (seg id)
  | _ -> fail 404 "not found"

let handle app req =
  try route app req with
  | Fail (status, msg) -> { status; body = error_body msg }
  | (Eio.Cancel.Cancelled _) as e -> raise e
  | e ->
      Printf.eprintf "error: %s %s: %s\n%!" req.meth req.path (Printexc.to_string e);
      { status = 500; body = error_body "internal error" }
