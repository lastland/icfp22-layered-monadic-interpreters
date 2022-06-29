(** * The Imp language  *)

(** We now demonstrate how to use ITrees in the context of verified compilation.
    To this end, we will consider a simple compiler from an imperative language
    to a control-flow-graph language.  The meaning of both languages will be
    given in terms of ITrees, so that the proof of correctness is expressed by
    proving a bisimulation between ITrees.

    We shall emphasize two main satisfying aspects of the resulting
    formalization.

    - Despite the correctness being termination-sensitive, we do not write any
      cofixpoints. All reasoning is purely equational, and the underlying
      coinductive reasoning is hidden on the library side.

    - We split the correctness in two steps. First, a linking theory of the CFG
      language is proved correct. Then, this theory is leveraged to prove the
      functional correctness of the compiler. The first piece is fairly generic,
      and hence reusable.
 *)

(** This tutorial is composed of the following files:
    - Utils_tutorial.v     : Utilities
    - Fin.v                : Finite types as a categorical embedding
    - KTreeFin.v           : Subcategory of ktrees over finite types
    - Imp.v                : Imp language, syntax and semantics
    - Asm.v                : Asm language, syntax and semantics
    - AsmCombinators.v     : Linking theory for Asm
    - Imp2Asm.v            : Compiler from Imp to Asm
    - Imp2AsmCorrectness.v : Proof of correctness of the compiler
    - AsmOptimizations.v   : (Optional) optimization passes for the Asm language
    The intended entry point for reading is Imp.v.
 *)

(** We start by introducing a simplified variant of Software
    Foundations' [Imp] language.  The language's semantics is first expressed in
    terms of [itree]s.  The semantics of the program can then be obtained by
    interpreting the events contained in the trees.
*)

(* begin hide *)
From Coq Require Import
     Arith.PeanoNat
     Lists.List
     Strings.String
     Morphisms
     Setoid
     RelationClasses.

From ExtLib Require Import
     Data.String
     Structures.Monad
     Data.List.

From ITree Require Import
     ITree
     ITreeFacts
     Basics.HeterogeneousRelations
     Basics.MonadState
     Basics.MonadFail
     Interp.HFunctor
     Interp.InterpFacts
     Events.MapDefault
     Events.Writer
     EqmR.EqmRMonad EqmR.EqmRMonadT
     EqmR.Monads.ErrorT EqmR.Monads.StateT.

Require Import Proofmode.

Import RelNotations.
Import ITreeNotations.
Import MonadNotation.
Import CatNotations.
Local Open Scope relationH_scope.
Local Open Scope cat_scope.
Local Open Scope monad_scope.
(* end hide *)

Opaque eqmR. Opaque interp.

(* ========================================================================== *)
(** ** Syntax *)

(** Imp manipulates a countable set of variables represented as [string]s: *)
Definition var : Set := string.

(** For simplicity, the language manipulates [nat]s as values. *)
Definition value : Type := nat.

(** Expressions are made of variables, constant literals, and arithmetic operations. *)
Inductive expr : Type :=
| Var (_ : var)
| Lit (_ : value)
| Plus  (_ _ : expr)
| Minus (_ _ : expr)
| Mult  (_ _ : expr).

(** The statements are straightforward. The [While] statement is the only
 potentially diverging one. *)

(** Here, we add a [Print] statement to the language to see how to extend
  the interpretation function. *)
Inductive stmt : Type :=
| Assign (x : var) (e : expr)    (* x = e *)
| Seq    (a b : stmt)            (* a ; b *)
| If     (i : expr) (t e : stmt) (* if (i) then { t } else { e } *)
| While  (t : expr) (b : stmt)   (* while (t) { b } *)
| Skip                           (* ; *)
| Abort
| Print  (s : string)
.

(* ========================================================================== *)
(** ** Notations *)

Module ImpNotations.

  (** A few notations for convenience.  *)
  Definition Var_coerce: string -> expr := Var.
  Definition Lit_coerce: nat -> expr := Lit.
  Coercion Var_coerce: string >-> expr.
  Coercion Lit_coerce: nat >-> expr.

  Bind Scope expr_scope with expr.

  Infix "+" := Plus : expr_scope.
  Infix "-" := Minus : expr_scope.
  Infix "*" := Mult : expr_scope.

  Bind Scope stmt_scope with stmt.

  Notation "x '←' e" :=
    (Assign x e) (at level 60, e at level 50): stmt_scope.

  Notation "a ';;;' b" :=
    (Seq a b)
      (at level 100, right associativity,
       format
         "'[v' a  ';;;' '/' '[' b ']' ']'"
      ): stmt_scope.

  Notation "'IF' i 'THEN' t 'ELSE' e 'FI'" :=
    (If i t e)
      (at level 100,
       right associativity,
       format
         "'[v ' 'IF'  i '/' '[' 'THEN'  t  ']' '/' '[' 'ELSE'  e ']' 'FI' ']'").

  Notation "'WHILE' t 'DO' b" :=
    (While t b)
      (at level 100,
       right associativity,
       format
         "'[v  ' 'WHILE'  t  'DO' '/' '[v' b  ']' ']'").

  Notation "'PRINT' s" :=
      (Print s)
        (at level 60,
        right associativity): stmt_scope.

End ImpNotations.

Import ImpNotations.

(* ========================================================================== *)
(** ** Semantics *)

(** _Imp_ produces effects by manipulating its variables.  To account for this,
    we define a type of _external interactions_ [ImpState] modeling reads and
    writes to global variables.

    A read, [GetVar], takes a variable as an argument and expects the
    environment to answer with a value, hence defining an event of type
    [ImpState value].

    Similarly, [SetVar] is a write event parameterized by both a variable and a
    value to be written, and defines an event of type [ImpState unit], no
    informative answer being expected from the environment.  *)
Variant ImpState : Type -> Type :=
| GetVar (x : var) : ImpState value
| SetVar (x : var) (v : value) : ImpState unit.

Definition exn := unit.

Variant ImpFail : Type -> Type :=
| Fail : ImpFail void.

Variant PrintE : Type -> Type :=
  | Out (s : string) : PrintE unit.

Section Denote.

  (** We now proceed to denote _Imp_ expressions and statements.
      We could simply fix in stone the universe of events to be considered,
      taking as a semantic domain for _Imp_ [itree ImpState X]. That would be
      sufficient to give meaning to _Imp_, but would prohibit us from relating this
      meaning to [itree]s stemmed from other entities. Therefore, we
      parameterize the denotation of _Imp_ by a larger universe of events [eff],
      of which [ImpState] is assumed to be a subevent. *)

  Context {E1 E2 E3 F : Type -> Type}.
  Context {HasImpState : ImpState +? E1 -< F}.
  Context {HasFail : ImpFail +? E2 -< F}.
  Context {HasPrint : PrintE +? E3 -< F}.

  (** _Imp_ expressions are denoted as [itree eff value], where the returned
      value in the tree is the value computed by the expression.
      In the [Var] case, the [trigger] operator smoothly lifts a single event to
      an [itree] by performing the corresponding [Vis] event and returning the
      environment's answer immediately.
      A constant (literal) is simply returned.
      Usual monadic notations are used in the other cases: we can [bind]
      recursive computations in the case of operators as one would expect. *)

  Fixpoint denote_expr (e : expr) : itree F value :=
    match e with
    | Var v     => trigger (GetVar v)
    | Lit n     => ret n
    | Plus a b  => l <- denote_expr a ;; r <- denote_expr b ;; ret (l + r)
    | Minus a b => l <- denote_expr a ;; r <- denote_expr b ;; ret (l - r)
    | Mult a b  => l <- denote_expr a ;; r <- denote_expr b ;; ret (l * r)
    end.

  (** We turn to the denotation of statements. As opposed to expressions,
      statements do not return any value: their semantic domain is therefore
      [itree eff unit]. The most interesting construct is, naturally, [while].

      To define its meaning, we make use of the [iter] combinator provided by
      the [itree] library:

      [iter : (A -> itree E (A + B)) -> A -> itree E B].

      The combinator takes as argument the body of the loop, i.e. a function
      that maps inputs of type [A], the accumulator, to an [itree] computing
      either a new [A] that can be fed back to the loop, or a return value of
      type [B]. The combinator builds the fixpoint of the body, hiding away the
      [A] argument from the return type.

      Compared to the [mrec] and [rec] combinators introduced in
      [Introduction.v], [iter] is more restricted in that it naturally
      represents tail recursive functions.  It, however, enjoys a rich equational
      theory: its addition grants the type of _continuation trees_ (named
      [ktree]s in the library), a structure of _traced monoidal category_.

      We use [loop] to first build a new combinator [while].
      The accumulator degenerates to a single [unit] value indicating
      whether we entered the body of the while loop or not. Since the
      the operation does not return any value, the return type is also
      taken to be [unit].
      That is, the right tag [inr tt] says to exit the loop,
      while the [inl tt] says to continue. *)

  Definition while (step : itree F (unit + unit)) : itree F unit :=
    iter (C := Kleisli _) (fun _ => step) tt.

  (** Casting values into [bool]:  [0] corresponds to [false] and any nonzero
      value corresponds to [true].  *)
  Definition is_true (v : value) : bool := if (v =? 0)%nat then false else true.

  (** The meaning of Imp statements is now easy to define.  They are all
      straightforward, except for [While], which uses our new [while] combinator
      over the computation that evaluates the conditional, and then the body if
      the former was true.  *)
  Fixpoint denote_imp (s : stmt) : itree F unit :=
    match s with
    | Assign x e =>  v <- denote_expr e ;; trigger (SetVar x v)
    | Seq a b    =>  denote_imp a ;; denote_imp b
    | If i t e   =>
      v <- denote_expr i ;;
      if is_true v then denote_imp t else denote_imp e

    | While t b =>
      while (v <- denote_expr t ;;
	           if is_true v
             then denote_imp b ;; ret (inl tt)
             else ret (inr tt))

    | Skip => ret tt
    | Abort => x <- trigger Fail;; match x:void with end
    | Print s => trigger (Out s)
    end.

End Denote.

(* ========================================================================== *)
(** ** EXAMPLE: Factorial *)

Section Example_Fact.

  (** We briefly illustrate the language by writing the traditional factorial.
      example.  *)

  Open Scope expr_scope.
  Open Scope stmt_scope.
  Variable input: var.
  Variable output: var.

  Definition fact (n:nat): stmt :=
    input ← n;;;
    output ← 1;;;
    PRINT "";;;
    WHILE input
    DO output ← output * input;;;
       input  ← input - 1.

  (** We have given _a_ notion of denotation to [fact 6] via [denote_imp].
      However, this is naturally not actually runnable yet, since it contains
      uninterpreted [ImpState] events.  We therefore now need to _handle_ the
      events contained in the trees, i.e. give a concrete interpretation of the
      environment.  *)

End Example_Fact.

(* ========================================================================== *)
(** ** Interpretation *)

(* begin hide *)
From ITree Require Import
     Events.MapDefault.

From ExtLib Require Import
     Core.RelDec
     Structures.Maps
     Data.Map.FMapAList.

(** These enable typeclass instances for Maps keyed by strings and values *)
Instance RelDec_string : RelDec (@eq string) :=
  { rel_dec := fun s1 s2 => if string_dec s1 s2 then true else false}.

Instance RelDec_string_Correct: RelDec_Correct RelDec_string.
Proof.
  constructor; intros x y.
  split.
  - unfold rel_dec; simpl.
    destruct (string_dec x y) eqn:EQ; [intros _; apply string_dec_sound; assumption | intros abs; inversion abs].
  - intros EQ; apply string_dec_sound in EQ; unfold rel_dec; simpl; rewrite EQ; reflexivity.
Qed.
(* end hide *)

(** We provide an _ITree event handler_ to interpret away [ImpState] events.  We
    use an _environment event_ to do so, modeling the environment as a
    0-initialized map from strings to values.  Recall from [Introduction.v] that
    a _handler_ for the events [ImpState] is a function of type [forall R, ImpState R
    -> M R] for some monad [M].  Here we take for our monad the special case of
    [M = itree E] for some universe of events [E] required to contain the
    environment events [mapE] provided by the library. It comes with an event
    interpreter [interp_map] that yields a computation in the state monad.  *)
Notation failT := (errorT exn).
Notation stateT := Monads.stateT.

Definition handle_ImpFail
           {E: Type -> Type}: ImpFail ~> failT (itree E) :=
  fun _ e =>
    match e with
    | Fail => ret (inl tt)
    end.

(** We now concretely implement this environment using ExtLib's finite maps. *)
Definition env := alist var value.

Definition ImpState_mapE : ImpState ~> mapE var 0 :=
  fun T e =>
    match e with
    | GetVar x => LookupDef x
    | SetVar x v => Insert x v
    end.

Definition handle_ImpState {E} : ImpState ~> stateT env (itree E) :=
    fun (T : Type) (X : ImpState T) => handle_map (ImpState_mapE T X).

Definition evalPrint {E : Type -> Type} : PrintE ~> itree E :=
  fun _ e =>
    match e with
    | Out s => ret tt
    end.

(** Finally, we can define an evaluator for our statements.
   To do so, we first denote them, leading to an [itree ImpState unit].
   We then [interp]ret [ImpState] into [mapE] using [handle_ImpState], leading to
   an [itree (mapE var value) unit].
   Finally, [interp_map] interprets the latter [itree] into the state monad,
   resulting in an [itree] free of any event, but returning the final
   _Imp_ env.
 *)

(** Note that in order to define [interp_imp] over a program [(s : itree F A)]
  where the event [F] is left abstract (with appropriate constraints for subevents),
  it is necessary to specify the monad transformer [T] for all outer interpretation
    functions and the underlying monad [M] for the innermost interpretation function.
  (Otherwise, the typeclass inference may diverge since there are ambiguous ways to
  compose monad transformers). *)
  Definition interp_imp {C D E F A}
             `{ImpState +? C -< D} `{ImpFail +? D -< E}
             `{PrintE +? E -< F}
            (s:itree F A) : (stateT env (failT (itree C))) A:=
    (interp (T := stateT env) (over handle_ImpFail)
            (interp (T := fun x => x) (over handle_ImpState)
                    (interp (M := itree E) (over evalPrint) s))).

  Definition eval_imp {E} (s: stmt) : stateT env (failT (itree E)) unit:=
    interp (T := stateT env) (over handle_ImpFail)
           (interp (over handle_ImpState)
                   (interp (over evalPrint) (denote_imp s))).

(** Equipped with this evaluator, we can now compute.
    Naturally since Coq is total, we cannot do it directly inside of it.
    We can either rely on extraction, or use some fuel.
 *)
Compute (burn 200 (eval_imp (fact "input" "output" 6)%string empty)).

(* ========================================================================== *)
Section InterpImpProperties.
  (** We can lift the underlying equational theory on [itree]s to include new
      equations for working with [interp_imp].

      In particular, we have:
         - [interp_imp] respects [≈]
         - [interp_imp] commutes with [bind].

      We could justify more equations than just the ones below.  For instance,
      _Imp_ programs also respect a coarser notation of equivalence for the
      [env] state.  We exploit this possibility to implement optimzations
      at the _Asm_ level (see AsmOptimizations.v).
   *)

  Context {E C1 C2 C3: Type -> Type}.
  Context {HasState: ImpState +? C1 -< C2}.
  Context {HasFail: ImpFail +? C2 -< C3}.
  Context {HasPrint: PrintE +? C3 -< E}.

  Instance env_inhabited : inhabited env.
    constructor; exact nil.
  Qed.

  (** This interpreter is compatible with the equivalence-up-to-tau. *)
  Global Instance eutt_interp_imp {A}:
    Proper (eqmR eq ==> eqmR eq) (interp_imp (A := A)).
  Proof.
    repeat intro; subst; unfold interp_imp.

    irewrite H.
  Qed.

  (** [interp_imp] commutes with [bind]. *)
  Lemma interp_imp_bind: forall {R S} (t: itree E R) (k: R -> itree E S),
      (interp_imp (ITree.bind t k))
        ≋ (fun g => sa <- interp_imp t g ;; interp_imp (k (snd sa)) (fst sa)).
  Proof.
    intros; unfold interp_imp.

    do 3 ibind. reflexivity.
  Qed.

End InterpImpProperties.

(** We now turn to our target language, in file [Asm].v *)
