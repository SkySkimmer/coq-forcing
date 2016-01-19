open Names
open Term
open Environ
open Globnames
open Pp

type translator = global_reference Refmap.t
exception MissingGlobal of global_reference

(** Yoneda embedding *)

type category = {
  cat_obj : Constr.t;
  (** Objects. Must be of type [Type]. *)
  cat_hom : Constr.t;
  (** Morphisms. Must be of type [cat_obj -> cat_obj -> Type]. *)
}

let obj_name = Name (Id.of_string "R")
let knt_name = Name (Id.of_string "k")

let hom cat a b =
  let lft = mkApp (cat.cat_hom, [| Vars.lift 1 b; mkRel 1 |]) in
  let rgt = mkApp (cat.cat_hom, [| Vars.lift 2 a; mkRel 2 |]) in
  let arr = mkArrow lft rgt in
  mkProd (obj_name, cat.cat_obj, arr)

let hom_type cat =
  mkLambda (obj_name, cat.cat_obj,
    mkLambda (obj_name, cat.cat_obj, hom cat (mkRel 2) (mkRel 1)))

let refl cat a =
  let hom = mkApp (cat.cat_hom, [| Vars.lift 1 a; mkRel 1 |]) in
  let lam = mkLambda (knt_name, hom, mkRel 1) in
  mkLambda (obj_name, cat.cat_obj, lam)

let trns cat a b c f g =
  let hom = mkApp (cat.cat_hom, [| Vars.lift 1 c; mkRel 1 |]) in
  let app = mkApp (Vars.lift 2 g, [| mkRel 2; mkRel 1 |]) in
  let app' = mkApp (Vars.lift 2 f, [| mkRel 2; app |]) in
  let lam = mkLambda (knt_name, hom, app') in
  mkLambda (obj_name, cat.cat_obj, lam)

(** Translation of types *)

let forcing_module =
  let dp = List.map Id.of_string ["Forcing"; "Forcing"] in
  ModPath.MPfile (DirPath.make dp)

let cType = (MutInd.make2 forcing_module (Label.make "Typeᶠ"), 0)
let ctype = (cType, 1)
let ptype = Projection.make (Constant.make2 forcing_module (Label.make "type")) false

(** Optimization of cuts *)

let mkOptApp (t, args) =
  let len = Array.length args in
  try
    let (_, t) = Term.decompose_lam_n len t in
    Vars.substl (CArray.rev_to_list args) t
  with _ ->
    mkApp (t, args)

let mkOptProj c = match kind_of_term c with
| App (i, args) ->
  if Array.length args = 5 && Term.isConstruct i then args.(3)
  else mkProj (ptype, c)
| _ ->
  mkProj (ptype, c)

(** Forcing translation *)

type forcing_condition =
| Variable
| Lift

type forcing_context = {
  context : forcing_condition list;
  (** Forcing contexts are flagging variables of the rel_context in the same
    order. We statically know that variables coming from the introduction of
    a forcing condition come by pairs: the first one is a level, the second one
    a morphism. There is therefore only [Lift] condition for such pairs. *)
  category : category;
  (** Underlying category *)
  translator : translator;
  (** A map associating to all source constant a forced constant *)
}

(** We assume that there is a hidden topmost variable [p : Obj] in the context *)

let pos_name = Name (Id.of_string "p")
let hom_name = Name (Id.of_string "α")

let dummy = mkProp

let last_condition fctx =
  let rec last fctx = match fctx with
  | [] -> 1
  | Variable :: fctx -> 1 + last fctx
  | Lift :: fctx -> 2
  in
  last fctx.context

let gather_morphisms n fctx =
  let rec gather i n fctx =
    if n = 0 then []
    else match fctx with
    | [] -> []
    | Variable :: fctx -> gather (i + 1) (n - 1) fctx
    | Lift :: fctx -> i :: gather (i + 2) n fctx
  in
  gather 1 n fctx.context

let morphism_var n fctx =
  let morphs = gather_morphisms n fctx in
  let last = mkRel (last_condition fctx) in
  let fold accu i =
    trns fctx.category dummy dummy last (mkRel i) accu
  in
  List.fold_left fold (refl fctx.category last) morphs

let get_var_shift n fctx =
  let rec get n fctx =
    if n = 0 then 0
    else match fctx with
    | [] -> n
    | Variable :: fctx -> 1 + get (n - 1) fctx
    | Lift :: fctx -> 2 + get n fctx
  in
  get n fctx.context

let extend fctx =
  let cat = fctx.category in
  let last = last_condition fctx in
  let ext = [(hom_name, None, hom cat (mkRel (1 + last)) (mkRel 1)); (pos_name, None, cat.cat_obj)] in
  (ext, { fctx with context = Lift :: fctx.context })

let add_variable fctx =
  { fctx with context = Variable :: fctx.context }

(** Macros *)

(** Given an inhabitant of CType build a Type *)
let projfType fctx c =
  let c = mkOptProj c in
  let last = mkRel (last_condition fctx) in
  mkOptApp (c, [| last; refl fctx.category last |])

(** Inverse *)
let mkfType env fctx sigma lam mon =
  let (sigma, pc) = Evd.fresh_constructor_instance env sigma ctype in
  let (ext0, fctx0) = extend fctx in
  let self = it_mkProd_or_LetIn (mkOptApp (Vars.lift 2 lam, [| mkRel 2; mkRel 1 |])) ext0 in
  let mon = mkLambda (Anonymous, self, mon) in
  let tpe = mkApp (mkConstructU pc, [| fctx.category.cat_obj; hom_type fctx.category; mkRel (last_condition fctx); lam; mon |]) in
  (sigma, tpe)

(** Parametricity conditions. Rel1 is bound to a boxed term of the right type *)

let type_mon env fctx sigma =
  let cat = fctx.category in
  let dummy = mkProp in
  let fctx = add_variable fctx in
  let eq = Coqlib.gen_constant "" ["Init"; "Logic"] "eq" in
  let (sigma, s) = Evd.new_sort_variable Evd.univ_flexible_alg sigma in
  let (ext, fctx) = extend fctx in
  let (ext0, fctx) = extend fctx in
  (** (A q f).type r g *)
  let lhs = mkApp (mkOptProj (mkApp (mkRel 5, [| mkRel 4; mkRel 3 |])), [| mkRel 2; mkRel 1 |]) in
  (** (A r (f o g)).type r id *)
  let rhs = mkApp (mkOptProj (mkApp (mkRel 5, [| mkRel 2; trns cat dummy dummy (mkRel 2) (mkRel 3) (mkRel 1) |])), [| mkRel 2; refl cat (mkRel 2) |]) in
  let mon = mkApp (eq, [| mkSort s; lhs; rhs |]) in
  let mon = it_mkProd_or_LetIn mon (ext0 @ ext) in
  (sigma, mon)

let prod_mon env fctx sigma na t u =
  (sigma, mkProp)

(** Handling of globals *) 

let translate_var fctx n =
  let p = mkRel (last_condition fctx) in
  let f = morphism_var n fctx in
  let m = get_var_shift n fctx in
  mkApp (mkRel m, [| p; f |])

let rec untranslate_rel n c = match Constr.kind c with
| App (t, args) when isRel t && Array.length args >= 2 ->
  c
| _ -> Constr.map_with_binders succ untranslate_rel n c

let fix_return_clause env fctx sigma r_ =
  (** The return clause must be mangled for the last variable *)
(*   msg_info (Termops.print_constr r_); *)
  let (args, r_) = decompose_lam_assum r_ in
  let ((na, _, self), args) = match args with h :: t -> (h, t) | _ -> assert false in
  (** Remove the forall boxing *)
  let self_ = match decompose_prod_n 2 self with
  | ([_; _], c) -> c
  | exception _ -> assert false
  in
  let last = last_condition fctx + List.length args in
  let (ext, _) = extend fctx in
  let r_ = untranslate_rel 1 r_ in
  let r_ = mkApp (r_, [| mkRel (last + 1); refl fctx.category (mkRel (last + 1)) |]) in
  let self_ = Vars.substl [refl fctx.category (mkRel last); (mkRel last)] self_ in
  let r_ = it_mkLambda_or_LetIn r_ ((na, None, self_) :: args) in
  msg_info (str "FINAL");
  msg_info (Termops.print_constr r_);
  (sigma, r_)

let apply_global env sigma gr u fctx =
  (** FIXME *)
  let p' =
    try Refmap.find gr fctx.translator
    with Not_found -> raise (MissingGlobal gr)
  in
  let (sigma, c) = Evd.fresh_global env sigma p' in
  let last = last_condition fctx in
  match gr with
  | IndRef _ ->
    let (_, oib) = Inductive.lookup_mind_specif env (fst (destInd c)) in
    (** First parameter is the toplevel forcing condition *)
    let _, paramtyp = CList.sep_last oib.mind_arity_ctxt in
    let nparams = List.length paramtyp in
    let fctx = List.fold_left (fun accu _ -> add_variable accu) fctx paramtyp in
    let (ext, fctx0) = extend fctx in
    let mk_var n =
      let n = nparams - n in
      let (ext0, fctx) = extend fctx0 in
      let ans = translate_var fctx n in
      it_mkLambda_or_LetIn ans ext0
    in
    let params = CList.init nparams mk_var in
    let app = applist (c, mkRel (last_condition fctx0) :: params) in
    let (sigma, tpe) = mkfType env fctx sigma (it_mkLambda_or_LetIn app ext) mkProp in
    let map_p i c = Vars.substnl_decl [mkRel last] (nparams - i - 1) c in
    let paramtyp = List.mapi map_p paramtyp in
    let ans = it_mkLambda_or_LetIn tpe paramtyp in
    (sigma, ans)
  | _ -> (sigma, mkApp (c, [| mkRel last |]))

(** Forcing translation core *)

let rec otranslate env fctx sigma c = match kind_of_term c with
| Rel n ->
  let ans = translate_var fctx n in
  (sigma, ans)
| Sort s ->
  let (ext0, _) = extend fctx in
  let (sigma, pi) = Evd.fresh_inductive_instance env sigma cType in
  let tpe = mkApp (mkIndU pi, [| fctx.category.cat_obj; hom_type fctx.category; mkRel 2 |]) in
  let lam = it_mkLambda_or_LetIn tpe ext0 in
  let (sigma, mon) = type_mon env fctx sigma in
  mkfType env fctx sigma lam mon
| Cast (c, k, t) ->
  let (sigma, c_) = otranslate env fctx sigma c in
  let (sigma, t_) = otranslate_type env fctx sigma t in
  let ans = mkCast (c_, k, t_) in
  (sigma, ans)
| Prod (na, t, u) ->
  let (ext0, fctx0) = extend fctx in
  (** Translation of t *)
  let (sigma, t_) = otranslate_boxed_type env fctx0 sigma t in
  (** Translation of u *)
  let ufctx = add_variable fctx0 in
  let (sigma, u_) = otranslate env ufctx sigma u in
  (** Result *)
  let ans = mkProd (na, t_, projfType ufctx u_) in
  let lam = it_mkLambda_or_LetIn ans ext0 in
  let (sigma, mon) = prod_mon env fctx sigma na t u in
  let (sigma, tpe) = mkfType env fctx sigma lam mon in
  (sigma, tpe)
| Lambda (na, t, u) ->
  (** Translation of t *)
  let (sigma, t_) = otranslate_boxed_type env fctx sigma t in
  (** Translation of u *)
  let ufctx = add_variable fctx in
  let (sigma, u_) = otranslate env ufctx sigma u in
  let ans = mkLambda (na, t_, u_) in
  (sigma, ans)
| LetIn (na, c, t, u) ->
  let (sigma, c_) = otranslate_boxed env fctx sigma c in
  let (sigma, t_) = otranslate_boxed_type env fctx sigma t in
  let ufctx = add_variable fctx in
  let (sigma, u_) = otranslate env ufctx sigma u in
  (sigma, mkLetIn (na, c_, t_, u_))
| App (t, args) ->
  let (sigma, t_) = otranslate env fctx sigma t in
  let fold sigma u = otranslate_boxed env fctx sigma u in
  let (sigma, args_) = CList.fold_map fold sigma (Array.to_list args) in
  let app = applist (t_, args_) in
  (sigma, app)
| Var id ->
  apply_global env sigma (VarRef id) Univ.Instance.empty fctx
| Const (p, u) ->
  apply_global env sigma (ConstRef p) u fctx
| Ind (i, u) ->
  apply_global env sigma (IndRef i) u fctx
| Construct (c, u) ->
  apply_global env sigma (ConstructRef c) u fctx
| Case (ci, r, c, p) ->
  let ind_ = match Refmap.find (IndRef ci.ci_ind) fctx.translator with
  | IndRef i -> i
  | _ -> assert false
  | exception Not_found -> raise (MissingGlobal (IndRef ci.ci_ind))
  in
  let ci_ = Inductiveops.make_case_info env ind_ ci.ci_pp_info.style in
  let (sigma, c_) = otranslate env fctx sigma c in

  let (sigma, r_) = otranslate env fctx sigma r in
  let (sigma, r_) = fix_return_clause env fctx sigma r_ in

  let fold sigma u = otranslate env fctx sigma u in
  let (sigma, p_) = CList.fold_map fold sigma (Array.to_list p) in
  let p_ = Array.of_list p_ in
  (sigma, mkCase (ci_, r_, c_, p_))
| Fix f -> assert false
| CoFix f -> assert false
| Proj (p, c) -> assert false
| Meta _ -> assert false
| Evar _ -> assert false

and otranslate_type env fctx sigma t =
  let (sigma, t_) = otranslate env fctx sigma t in
  let t_ = projfType fctx t_ in
  (sigma, t_)

and otranslate_boxed env fctx sigma t =
  let (ext, ufctx) = extend fctx in
  let (sigma, t_) = otranslate env ufctx sigma t in
  let t_ = it_mkLambda_or_LetIn t_ ext in
  (sigma, t_)

and otranslate_boxed_type env fctx sigma t =
  let (ext, ufctx) = extend fctx in
  let (sigma, t_) = otranslate_type env ufctx sigma t in
  let t_ = it_mkProd_or_LetIn t_ ext in
  (sigma, t_)

let empty translator cat lift env =
  let ctx = rel_context env in
  let empty = { context = []; category = cat; translator; } in
  let empty = List.fold_right (fun _ fctx -> add_variable fctx) ctx empty in
  let rec flift fctx n =
    if n = 0 then fctx
    else flift (snd (extend fctx)) (pred n)
  in
  flift empty (match lift with None -> 0 | Some n -> n)

(** The toplevel option allows to close over the topmost forcing condition *)

let translate ?(toplevel = true) ?lift translator cat env sigma c =
  let empty = empty translator cat lift env in
  let (sigma, c) = otranslate env empty sigma c in
  let ans = if toplevel then mkLambda (pos_name, cat.cat_obj, c) else c in
  (sigma, ans)

let translate_type ?(toplevel = true) ?lift translator cat env sigma c =
  let empty = empty translator cat lift env in
  let (sigma, c) = otranslate_type env empty sigma c in
  let ans = if toplevel then mkProd (pos_name, cat.cat_obj, c) else c in
  (sigma, ans)

let translate_context ?(toplevel = true) ?lift translator cat env sigma ctx =
  let empty = empty translator cat lift env in
  let fold (na, body, t) (sigma, fctx, ctx_) =
    let (sigma, body_) = match body with
    | None -> (sigma, None)
    | Some _ -> assert false
    in
    let (ext, tfctx) = extend fctx in
    let (sigma, t_) = otranslate_type env tfctx sigma t in
    let t_ = it_mkProd_or_LetIn t_ ext in
    let decl_ = (na, body_, t_) in
    let fctx = add_variable fctx in
    (sigma, fctx, decl_ :: ctx_)
  in
  let init = if toplevel then [pos_name, None, cat.cat_obj] else [] in
  let (sigma, _, ctx_) = List.fold_right fold ctx (sigma, empty, init) in
  (sigma, ctx_)
