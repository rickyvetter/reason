(*
  This is the file that handles turning Reason JSX' agnostic function call into
  a ReasonReact-specific function call. Aka, this is a macro, using OCaml's ppx
  facilities; https://whitequark.org/blog/2014/04/16/a-guide-to-extension-
  points-in-ocaml/

  You wouldn't use this file directly; it's used by BuckleScript's
  bsconfig.json. Specifically, there's a field called `react-jsx` inside the
  field `reason`, which enables this ppx through some internal call in bsb
*)

(*
  The actual transform:

  transform `[@JSX] div(~props1=a, ~props2=b, ~children=[foo, bar], ())` into
  `ReactDOMRe.createElement("div", ~props={"props1": 1, "props2": b}, [|foo,
  bar|])`.

  transform `[@JSX] div(~props1=a, ~props2=b, ~children=foo, ())` into
  `ReactDOMRe.createElementVariadic("div", ~props={"props1": 1, "props2": b}, foo)`.

  transform the upper-cased case
  `[@JSX] Foo.createElement(~key=a, ~ref=b, ~foo=bar, ~children=[], ())` into
  `ReasonReact.element(~key=a, ~ref=b, Foo.make(~foo=bar, [||]))`

  transform `[@JSX] [foo]` into
  `ReactDOMRe.createElement(ReasonReact.fragment, [|foo|])`
*)

(*
  This file's shared between the Reason repo and the BuckleScript repo. In
  Reason, it's in src. In BuckleScript, it's in jscomp/bin. We periodically
  copy this file from Reason (the source of truth) to BuckleScript, then
  uncomment the #if #else #end cppo macros you see in the file. That's because
  BuckleScript's on OCaml 4.02 while Reason's on 4.04; so the #if macros
  surround the pieces of code that are different between the two compilers.

  When you modify this file, please make sure you're not dragging in too many
  things. You don't necessarily have to test the file on both Reason and
  BuckleScript; ping @chenglou and a few others and we'll keep them synced up by
  patching the right parts, through the power of types(tm)
*)

(* #if defined BS_NO_COMPILER_PATCH then *)
open Migrate_parsetree
open Ast_404
module To_current = Convert(OCaml_404)(OCaml_current)

let nolabel = Ast_404.Asttypes.Nolabel
let labelled str = Ast_404.Asttypes.Labelled str
let argIsKeyRef = function
  | (Asttypes.Labelled ("key" | "ref"), _) | (Asttypes.Optional ("key" | "ref"), _) -> true
  | _ -> false
let constantString ~loc str = Ast_helper.Exp.constant ~loc (Parsetree.Pconst_string (str, None))
(* #else
let nolabel = ""
let labelled str = str
let argIsKeyRef = function
  | (("key" | "ref"), _) | (("?key" | "?ref"), _) -> true
  | _ -> false
let constantString ~loc str = Ast_helper.Exp.constant ~loc (Asttypes.Const_string (str, None))
#end *)

open Ast_helper
open Ast_mapper
open Asttypes
open Parsetree
open Longident

type 'a children = | ListLiteral of 'a | Exact of 'a

(* if children is a list, convert it to an array while mapping each element. If not, just map over it, as usual *)
let transformChildrenIfListUpper ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} -> begin
      match accum with
      | [singleElement] -> Exact singleElement
      | accum -> ListLiteral (List.rev accum |> Exp.array ~loc)
      end
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> Exact (mapper.expr mapper notAList)
  in
  transformChildren_ theList []

let transformChildrenIfList ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} ->
      List.rev accum |> Exp.array ~loc
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> mapper.expr mapper notAList
  in
  transformChildren_ theList []

let extractChildren ?(removeLastPositionUnit=false) ~loc propsAndChildren =
  let rec allButLast_ lst acc = match lst with
    | [] -> []
(* #if defined BS_NO_COMPILER_PATCH then *)
    | (Nolabel, {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | (Nolabel, _)::_ -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
(* #else
    | ("", {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | ("", _)::rest -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
#end *)
    | arg::rest -> allButLast_ rest (arg::acc)
  in
  let allButLast lst = allButLast_ lst [] |> List.rev in
  match (List.partition (fun (label, _) -> label = labelled "children") propsAndChildren) with
  | ([], props) ->
    (* no children provided? Place a placeholder list *)
    (Exp.construct ~loc {loc; txt = Lident "[]"} None, if removeLastPositionUnit then allButLast props else props)
  | ([(_, childrenExpr)], props) ->
    (childrenExpr, if removeLastPositionUnit then allButLast props else props)
  | _ -> raise (Invalid_argument "JSX: somehow there's more than one `children` label")

(* TODO: some line number might still be wrong *)
let jsxMapper () =

  let jsxVersion = ref None in

  let transformUppercaseCall3 modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let argsForMake = argsWithLabels in
    let childrenExpr = transformChildrenIfListUpper ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let args = recursivelyTransformedArgsForMake
      @ (match childrenExpr with
        | Exact children -> [(Labelled "children", children)]
        | ListLiteral ({ pexp_desc = Pexp_array list } as expression) when list = [] -> []
        | ListLiteral expression ->
          let fragment = Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "fragment")} in
          let args = [
            (nolabel, fragment);
            (nolabel, expression)
          ] in
        [(Labelled "children", Exp.apply
          ~loc
          (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactHooks", "createElement")})
          args)]) in
    let ident = match modulePath with
    | Lident justModule -> Ldot (modulePath, "make")
    | modulePath -> modulePath in
    let propsIdent = match modulePath with
    | Lident justModule -> Ldot (modulePath, "props")
    | Ldot(ident, path) -> Ldot (ident, path ^ "_props")
    | modulePath -> modulePath in
    (* handle key, ref, children *)
    let wrapWithReasonReactElement e = (* ReactHooks.createElement(Component.make, props, ...children) *)
      Exp.apply
        ~loc
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactHooks", "createElement")})
        ([
          (nolabel, Exp.ident ~loc {txt = ident; loc});
          (nolabel, Exp.apply
          ~attrs
          (Exp.ident ~loc {loc; txt = propsIdent})
          args);
        ]) in
    Exp.apply
      ~loc
      ~attrs
      (* Foo.make *)
      (Exp.ident ~loc {loc; txt = propsIdent})
      args
    |> wrapWithReasonReactElement in

    let transformLowercaseCall3 mapper loc attrs callArguments id =
      let (children, nonChildrenProps) = extractChildren ~loc callArguments in
      let componentNameExpr = constantString ~loc id in
      let childrenExpr = transformChildrenIfList ~loc ~mapper children in
      let createElementCall = match children with
        (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
        | {
            pexp_desc =
             Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
             | Pexp_construct ({txt = Lident "[]"}, None)
          } -> "createDOMElement"
        (* [@JSX] div(~children= value), coming from <div> ...(value) </div> *)
        | _ -> raise (Invalid_argument "A spread as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      in
      let args = match nonChildrenProps with
        | [_justTheUnitArgumentAtEnd] ->
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ]
        | nonEmptyProps ->
          let propsCall =
            Exp.apply
              ~loc
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactHooks", "domProps")})
              (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
          in
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
            (labelled "props", propsCall);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ] in
      Exp.apply
        ~loc
        (* throw away the [@JSX] attribute and keep the others, if any *)
        ~attrs
        (* ReactDOMRe.createElement *)
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactHooks", createElementCall)})
        args
    in

  let transformUppercaseCall modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let (argsKeyRef, argsForMake) = List.partition argIsKeyRef argsWithLabels in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let args = recursivelyTransformedArgsForMake @ [ (nolabel, childrenExpr) ] in
    let wrapWithReasonReactElement e = (* ReasonReact.element(~key, ~ref, ...) *)
      Exp.apply
        ~loc
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "element")})
        (argsKeyRef @ [(nolabel, e)]) in
    Exp.apply
      ~loc
      ~attrs
      (* Foo.make *)
      (Exp.ident ~loc {loc; txt = Ldot (modulePath, "make")})
      args
    |> wrapWithReasonReactElement in

  let transformLowercaseCall mapper loc attrs callArguments id =
    let (children, nonChildrenProps) = extractChildren ~loc callArguments in
    let componentNameExpr = constantString ~loc id in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let createElementCall = match children with
      (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
      | {
          pexp_desc =
           Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
           | Pexp_construct ({txt = Lident "[]"}, None)
        } -> "createElement"
      (* [@JSX] div(~children=[|a|]), coming from <div> ...[|a|] </div> *)
      | { pexp_desc = (Pexp_array _) } ->
        raise (Invalid_argument "A spread + an array literal as a DOM element's \
          children would cancel each other out, and thus don't make sense written \
          together. You can simply remove the spread and the array literal.")
      (* [@JSX] div(~children= <div />), coming from <div> ...<div/> </div> *)
      | {
          pexp_attributes
        } when pexp_attributes |> List.exists (fun (attribute, _) -> attribute.txt = "JSX") ->
        raise (Invalid_argument "A spread + a JSX literal as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      | _ -> "createElementVariadic"
    in
    let args = match nonChildrenProps with
      | [_justTheUnitArgumentAtEnd] ->
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ]
      | nonEmptyProps ->
        let propsCall =
          Exp.apply
            ~loc
            (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "props")})
            (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
        in
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
          (labelled "props", propsCall);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ] in
    Exp.apply
      ~loc
      (* throw away the [@JSX] attribute and keep the others, if any *)
      ~attrs
      (* ReactDOMRe.createElement *)
      (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", createElementCall)})
      args
  in

  let rec recursivelyTransformNamedArgsForMake expr list =
    match expr.pexp_desc with
    | Pexp_fun (Labelled(label), defaultArg, _, expression) ->
        recursivelyTransformNamedArgsForMake expression ((label, defaultArg, false) :: list)
    | Pexp_fun (Optional(label), defaultArg, _, expression) ->
        recursivelyTransformNamedArgsForMake expression ((label, defaultArg, true) :: list)
    | Pexp_fun (Nolabel, _, { ppat_desc = (Ppat_construct ({txt = Lident "()"}, _) | Ppat_any)}, expression) ->
        (expression.pexp_desc, list)
    | innerExpression -> (innerExpression, list)
  in

  let rec recursivelyMakeNamedArgsForExternal loc list args = match list with
  | (label, _, optional)::tl ->
    recursivelyMakeNamedArgsForExternal loc tl (Ast_404.Ast_helper.Typ.arrow
    (if optional then Optional(label) else Labelled(label))
    {
      ptyp_desc = Ptyp_var label;
      ptyp_loc = loc;
      ptyp_attributes = [];
    } args)
  | [] -> args
  in

  let transformComponentDefinition structure returnStructures = match structure with
  | {
      pstr_loc;
      pstr_desc = Pstr_value (
        foo,
        valueBindings
      )
    } ->
      let typeDecls = ref [] in
      let externals = ref [] in
      let names = ref [] in
      let bsRawCreate functionName variableName =
        functionName ^ ".name = '" ^ variableName ^ "';" in
      let setNamesForBSRaw functionName ((loc, payload) as attr) =
        let setNames str = match str with
        | {pstr_desc = Pstr_eval ({
          pexp_desc = Pexp_constant (Pconst_string (str, delim))
        } as innest , _)} as inner ->
          let name = {inner with pstr_desc = Pstr_eval (
            {innest with pexp_desc = Pexp_extension (
              {txt = "bs.raw"; loc = loc.loc},
              PStr [
              {inner with pstr_desc = Pstr_eval (
                {innest with pexp_desc = Pexp_constant (Pconst_string (bsRawCreate functionName str, delim))},
                []
              )}]
            )},
            []
          )} in
          (* todo: add __MODULE__ here *)
          names := name :: !names
        | _ -> () in
        (match loc with
        | {txt = "react.component"} ->
          (match payload with
          | PStr structures ->
            List.iter setNames structures
          | _ -> ())
        | _ -> ())
      in
      let hasAttr (loc, _) =
        loc.txt = "react.component" in
      let otherAttrsPure (loc, _) =
        loc.txt <> "react.component" in
      let hasAttrOnBinding {pvb_attributes} = match (List.find_opt hasAttr pvb_attributes) with | Some(_) -> true | None -> false in
      let filterAttrOnBinding binding = {binding with pvb_attributes = List.filter otherAttrsPure binding.pvb_attributes} in
      let mapBinding binding = if (hasAttrOnBinding binding) then
        let fnName = match binding with
        | {pvb_pat = {
            ppat_desc = Ppat_var {txt}
          }} -> txt
        | _ -> raise (Invalid_argument "react.component should only be used on a function declaration.") in
        let _ = List.iter (setNamesForBSRaw fnName) binding.pvb_attributes in
        let binding = filterAttrOnBinding binding in
        (* do stuff here! *)
        let (innerFunctionExpression, namedArgList) = recursivelyTransformNamedArgsForMake binding.pvb_expr [] in
        let argToType (name, _optionalExpression, _) = (name, [], {
          ptyp_desc = Ptyp_var name;
          ptyp_loc = pstr_loc;
          ptyp_attributes = [];
          }) in
        let pluckType (_, _, coreType) = coreType in
        let argToTypeParam (name, _optionalExpression, _) = ({
          ptyp_desc = Ptyp_var name;
          ptyp_loc = pstr_loc;
          ptyp_attributes = [];
          }, Invariant) in
        let namedArgListWithKey = ("key", None, true) :: namedArgList in
        let namedTypeList = List.map argToType namedArgList in
        let justNamedTypeList = List.map pluckType namedTypeList in
        let namedTypeParamsList = List.map argToTypeParam namedArgList in

        let typeDecl = {pstr_desc= Pstr_type (Recursive, [{
          (* ptype_params = foo; *)
          ptype_name = {txt = "t"; loc = pstr_loc};
          ptype_params = namedTypeParamsList;
          ptype_loc = pstr_loc;
          ptype_cstrs = [];
          ptype_kind = Ptype_abstract;
          ptype_private = Public;
          ptype_attributes = [];
          ptype_manifest = Some({
            ptyp_desc = Ptyp_constr({txt= Lident("Js.t"); loc= pstr_loc}, [{
                ptyp_desc = Ptyp_object(namedTypeList, Closed);
                ptyp_loc = pstr_loc;
                ptyp_attributes = [];
              }]);
            ptyp_loc = pstr_loc;
            ptyp_attributes = [];
            });
          }]);
          pstr_loc = pstr_loc} in
          let _ = typeDecls := typeDecl :: !typeDecls in

        let externalDecl = {
          pstr_loc = pstr_loc;
          pstr_desc = Pstr_primitive {
            pval_name = {txt = "props"; loc = pstr_loc};
            pval_type =
               recursivelyMakeNamedArgsForExternal
                 pstr_loc
                 namedArgListWithKey
                 (Ast_404.Ast_helper.Typ.arrow
                 Nolabel
                 {
                   ptyp_desc = Ptyp_constr ({txt= Lident("unit"); loc = pstr_loc}, []);
                   ptyp_loc = pstr_loc;
                   ptyp_attributes = [];
                 }
                 (Ast_404.Ast_helper.Typ.mk(Ptyp_constr({txt= Lident("t"); loc= pstr_loc}, justNamedTypeList))));
            pval_prim = [];
            pval_attributes = [({txt = "bs.obj"; loc = pstr_loc}, PStr [])];
            pval_loc = pstr_loc;
          }
        } in
        let _ = externals := externalDecl :: !externals in
        let makeLet (label, _, optional) =
          Ast_404.Ast_helper.Vb.mk
            (Ast_404.Ast_helper.Pat.var {txt = label; loc = pstr_loc})
            (Ast_404.Ast_helper.Exp.apply
              (Ast_404.Ast_helper.Exp.ident {txt = (Lident "##"); loc = pstr_loc })
              [
                (Nolabel, Ast_404.Ast_helper.Exp.ident {txt = (Lident "__reactprops__"); loc = pstr_loc });
                (Nolabel, Ast_404.Ast_helper.Exp.ident {txt = (Lident label); loc = pstr_loc })
              ]
            ) in
        let innerLets = List.map makeLet namedArgList in
        let innerExpression = Ast_404.Ast_helper.Exp.mk innerFunctionExpression in
        let innerExpression = (match innerLets with
        | [] -> innerExpression
        | innerLets -> Ast_404.Ast_helper.Exp.mk(Pexp_let (
          Nonrecursive,
          innerLets,
          innerExpression
        ))) in
        {
          binding with
          pvb_expr = Ast_404.Ast_helper.Exp.mk
          ~attrs:[({loc = pstr_loc; txt = "bs.uncurry"}, PStr [])]
          (Pexp_fun (
            Nolabel,
            None,
            {
              ppat_desc = Ppat_var {txt = "__reactprops__"; loc = pstr_loc};
              ppat_loc = pstr_loc;
              ppat_attributes = [];
            },
            innerExpression
          ))
        }
      else
        binding
      in
      let mappedBindings = List.map mapBinding valueBindings in
      let returnStructures = {
          pstr_loc;
          pstr_desc = Pstr_value (
            foo,
            mappedBindings
          )
      } :: returnStructures in
      let returnStructures = if !externals != [] then
        List.concat [!externals; returnStructures] else begin
        returnStructures end in
      let returnStructures = if !typeDecls != [] then
        List.concat [!typeDecls; returnStructures] else begin
        returnStructures end in
      let returnStructures = if !names != [] then
        List.concat [returnStructures; !names] else begin
        returnStructures end in
      returnStructures
    | structure -> structure :: returnStructures in

  let reactComponentTransform structures =
  (* [] in *)
  List.fold_right transformComponentDefinition structures [] in


  let transformJsxCall mapper callExpression callArguments attrs =
    (match callExpression.pexp_desc with
     | Pexp_ident caller ->
       (match caller with
        | {txt = Lident "createElement"} ->
          raise (Invalid_argument "JSX: `createElement` should be preceeded by a module name.")

        (* Foo.createElement(~prop1=foo, ~prop2=bar, ~children=[], ()) *)
        | {loc; txt = Ldot (modulePath, ("createElement" | "make"))} ->
          (match !jsxVersion with
          | None
          | Some 2 -> transformUppercaseCall modulePath mapper loc attrs callExpression callArguments
          | Some 3 -> transformUppercaseCall3 modulePath mapper loc attrs callExpression callArguments
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        (* div(~prop1=foo, ~prop2=bar, ~children=[bla], ()) *)
        (* turn that into
          ReactDOMRe.createElement(~props=ReactDOMRe.props(~props1=foo, ~props2=bar, ()), [|bla|]) *)
        | {loc; txt = Lident id} ->
          (match !jsxVersion with
          | None
          | Some 2 -> transformLowercaseCall mapper loc attrs callArguments id
          | Some 3 -> transformLowercaseCall3 mapper loc attrs callArguments id
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        | {txt = Ldot (_, anythingNotCreateElementOrMake)} ->
          raise (
            Invalid_argument
              ("JSX: the JSX attribute should be attached to a `YourModuleName.createElement` or `YourModuleName.make` call. We saw `"
               ^ anythingNotCreateElementOrMake
               ^ "` instead"
              )
          )

        | {txt = Lapply _} ->
          (* don't think there's ever a case where this is reached *)
          raise (
            Invalid_argument "JSX: encountered a weird case while processing the code. Please report this!"
          )
       )
     | _ ->
       raise (
         Invalid_argument "JSX: `createElement` should be preceeded by a simple, direct module name."
       )
    ) in

  let structure =
    (fun mapper structure -> match structure with
      (*
        match against [@bs.config {foo, jsx: ...}] at the file-level. This
        indicates which version of JSX we're using. This code stays here because
        we used to have 2 versions of JSX PPX (and likely will again in the
        future when JSX PPX changes). So the architecture for switching between
        JSX behavior stayed here. To create a new JSX ppx, copy paste this
        entire file and change the relevant parts.

        Description of architecture: in bucklescript's bsconfig.json, you can
        specify a project-wide JSX version. You can also specify a file-level
        JSX version. This degree of freedom allows a person to convert a project
        one file at time onto the new JSX, when it was released. It also enabled
        a project to depend on a third-party which is still using an old version
        of JSX
      *)
      | {
          pstr_loc;
          pstr_desc = Pstr_attribute (
            ({txt = "bs.config"} as bsConfigLabel),
            PStr [{pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (recordFields, b)} as innerConfigRecord, a)} as configRecord]
          )
        }::restOfStructure -> begin
          let (jsxField, recordFieldsWithoutJsx) = recordFields |> List.partition (fun ({txt}, _) -> txt = Lident "jsx") in
          match (jsxField, recordFieldsWithoutJsx) with
          (* no file-level jsx config found *)
          | ([], _) -> default_mapper.structure mapper structure
          (* {jsx: 2} *)
(* #if defined BS_NO_COMPILER_PATCH then *)
          | ((_, {pexp_desc = Pexp_constant (Pconst_integer (version, _))})::_, recordFieldsWithoutJsx) -> begin
              (match version with
              | "2" -> jsxVersion := Some 2
              | "3" -> jsxVersion := Some 3
              | _ -> raise (Invalid_argument "JSX: the file-level bs.config's jsx version must be 2 or 3"));
(* #else
          | ((_, {pexp_desc = Pexp_constant (Const_int version)})::rest, recordFieldsWithoutJsx) -> begin
              (match version with
              | 2 -> jsxVersion := Some 2
              | 3 -> jsxVersion := Some 3
              | _ -> raise (Invalid_argument "JSX: the file-level bs.config's jsx version must be 2 or 3"));
#end *)
              match recordFieldsWithoutJsx with
              (* record empty now, remove the whole bs.config attribute *)
              | [] -> default_mapper.structure mapper @@ reactComponentTransform restOfStructure
              | fields -> default_mapper.structure mapper ({
                pstr_loc;
                pstr_desc = Pstr_attribute (
                  bsConfigLabel,
                  PStr [{configRecord with pstr_desc = Pstr_eval ({innerConfigRecord with pexp_desc = Pexp_record (fields, b)}, a)}]
                )
                (* TODO: remove? idk. seems a bit iffy *)
              }::(reactComponentTransform restOfStructure))
            end
        | _ -> raise (Invalid_argument "JSX: the file-level bs.config's {jsx: ...} config accepts only a version number")
      end
      (*
        fuuuck yes. react.component bitches
      *)
      | structures -> begin
        (* TODO: remove default mapper? idk. seems a bit iffy *)
        default_mapper.structure mapper @@ reactComponentTransform structures
      end
    ) in

  let expr =
    (fun mapper expression -> match expression with
       (* Does the function application have the @JSX attribute? *)
       | {
           pexp_desc = Pexp_apply (callExpression, callArguments);
           pexp_attributes
         } ->
         let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
         (match (jsxAttribute, nonJSXAttributes) with
         (* no JSX attribute *)
         | ([], _) -> default_mapper.expr mapper expression
         | (_, nonJSXAttributes) -> transformJsxCall mapper callExpression callArguments nonJSXAttributes)

       (* is it a list with jsx attribute? Reason <>foo</> desugars to [@JSX][foo]*)
       | {
           pexp_desc =
            Pexp_construct ({txt = Lident "::"; loc}, Some {pexp_desc = Pexp_tuple _})
            | Pexp_construct ({txt = Lident "[]"; loc}, None);
           pexp_attributes
         } as listItems ->
          let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
          (match (jsxAttribute, nonJSXAttributes) with
          (* no JSX attribute *)
          | ([], _) -> default_mapper.expr mapper expression
          | (_, nonJSXAttributes) ->
            let fragment = Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "fragment")} in
            let childrenExpr = transformChildrenIfList ~loc ~mapper listItems in
            let args = [
              (* "div" *)
              (nolabel, fragment);
              (* [|moreCreateElementCallsHere|] *)
              (nolabel, childrenExpr)
            ] in
            Exp.apply
              ~loc
              (* throw away the [@JSX] attribute and keep the others, if any *)
              ~attrs:nonJSXAttributes
              (* ReactDOMRe.createElement *)
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "createElement")})
              args
         )
       (* Delegate to the default mapper, a deep identity traversal *)
       | e -> default_mapper.expr mapper e) in

(* #if defined BS_NO_COMPILER_PATCH then *)
  To_current.copy_mapper { default_mapper with structure; expr }
(* #else
  { default_mapper with structure; expr }
#end *)

(* #if BS_COMPILER_IN_BROWSER then

module Js = struct
  module Unsafe = struct
    type any
    external inject : 'a -> any = "%identity"
    external get : 'a -> 'b -> 'c = "caml_js_get"
    external set : 'a -> 'b -> 'c -> unit = "caml_js_set"
    external pure_js_expr : string -> 'a = "caml_pure_js_expr"
    let global = pure_js_expr "joo_global_object"
    external obj : (string * any) array -> 'a = "caml_js_object"
  end
  type (-'a, +'b) meth_callback
  type 'a callback = (unit, 'a) meth_callback
  external wrap_meth_callback : ('a -> 'b) -> ('a, 'b) meth_callback = "caml_js_wrap_meth_callback"
  type + 'a t
  type js_string
  external string : string -> js_string t = "caml_js_from_string"
  external to_string : js_string t -> string = "caml_js_to_string"
end

(* keep in sync with jscomp/core/jsoo_main.ml `let implementation` *)
let rewrite code =
  let mapper = jsxMapper () in
  Location.input_name := "//toplevel//";
  try
    let lexer = Lexing.from_string code in
    let pstr = Parse.implementation lexer in
    let pstr = mapper.structure mapper pstr in
    let buffer = Buffer.create 1000 in
    Pprintast.structure Format.str_formatter pstr;
    let ocaml_code = Format.flush_str_formatter () in
    Js.Unsafe.(obj [| "ocaml_code", inject @@ Js.string ocaml_code |])
  with e ->
    match Location.error_of_exn e with
    | Some error ->
        Location.report_error Format.err_formatter error;
        let (file, line, startchar) = Location.get_pos_info error.loc.loc_start in
        let (file, endline, endchar) = Location.get_pos_info error.loc.loc_end in
        Js.Unsafe.(obj
          [|
            "ppx_error_msg", inject @@ Js.string (Printf.sprintf "Line %d, %d: %s" line startchar error.msg);
            "row", inject (line - 1);
            "column", inject startchar;
            "endRow", inject (endline - 1);
            "endColumn", inject endchar;
            "text", inject @@ Js.string error.msg;
            "type", inject @@ Js.string "error";
          |]
        )
    | None ->
        Js.Unsafe.(obj [|
          "js_error_msg" , inject @@ Js.string (Printexc.to_string e)
        |])

let export (field : string) v =
  Js.Unsafe.set (Js.Unsafe.global) field v

let make_ppx name =
  export name
    (Js.Unsafe.(obj
                  [|"rewrite",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code -> rewrite (Js.to_string code));
                  |]))

let () = make_ppx "jsxv2" *)

(* #elif defined BS_NO_COMPILER_PATCH then *)
let () = Compiler_libs.Ast_mapper.register "JSX" (fun _argv -> jsxMapper ())
(* #else
let () = Ast_mapper.register "JSX" (fun _argv -> jsxMapper ())
#end *)
