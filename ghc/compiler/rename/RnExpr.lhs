%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnExpr]{Renaming of expressions}

Basically dependency analysis.

Handles @Match@, @GRHSs@, @HsExpr@, and @Qualifier@ datatypes.  In
general, all of these functions return a renamed thing, and a set of
free variables.

\begin{code}
module RnExpr (
	rnMatch, rnGRHSs, rnPat, rnExpr, rnExprs,
	checkPrecMatch
   ) where

#include "HsVersions.h"

import {-# SOURCE #-} RnBinds  ( rnBinds ) 
import {-# SOURCE #-} RnSource ( rnHsTypeFVs )

import HsSyn
import RdrHsSyn
import RnHsSyn
import RnMonad
import RnEnv
import RnHiFiles	( lookupFixityRn )
import CmdLineOpts	( DynFlag(..), opt_IgnoreAsserts )
import Literal		( inIntRange )
import BasicTypes	( Fixity(..), FixityDirection(..), defaultFixity, negateFixity )
import PrelNames	( hasKey, assertIdKey,
			  eqClass_RDR, foldr_RDR, build_RDR, eqString_RDR,
			  cCallableClass_RDR, cReturnableClass_RDR, 
			  monadClass_RDR, enumClass_RDR, ordClass_RDR,
			  ratioDataCon_RDR, negate_RDR, assertErr_RDR,
			  ioDataCon_RDR, plusInteger_RDR, timesInteger_RDR
			)
import TysPrim		( charPrimTyCon, addrPrimTyCon, intPrimTyCon, 
			  floatPrimTyCon, doublePrimTyCon
			)
import TysWiredIn	( intTyCon )
import Name		( NamedThing(..), mkSysLocalName, nameSrcLoc )
import NameSet
import UniqFM		( isNullUFM )
import FiniteMap	( elemFM )
import UniqSet		( emptyUniqSet )
import List		( intersectBy )
import ListSetOps	( unionLists, removeDups )
import Maybes		( maybeToBool )
import Outputable
\end{code}


*********************************************************
*							*
\subsection{Patterns}
*							*
*********************************************************

\begin{code}
rnPat :: RdrNamePat -> RnMS (RenamedPat, FreeVars)

rnPat WildPatIn = returnRn (WildPatIn, emptyFVs)

rnPat (VarPatIn name)
  = lookupBndrRn  name			`thenRn` \ vname ->
    returnRn (VarPatIn vname, emptyFVs)

rnPat (SigPatIn pat ty)
  = doptRn Opt_GlasgowExts `thenRn` \ glaExts ->
    
    if glaExts
    then rnPat pat		`thenRn` \ (pat', fvs1) ->
         rnHsTypeFVs doc ty	`thenRn` \ (ty',  fvs2) ->
         returnRn (SigPatIn pat' ty', fvs1 `plusFV` fvs2)

    else addErrRn (patSigErr ty)	`thenRn_`
         rnPat pat
  where
    doc = text "a pattern type-signature"
    
rnPat (LitPatIn s@(HsString _)) 
  = lookupOrigName eqString_RDR		`thenRn` \ eq ->
    returnRn (LitPatIn s, unitFV eq)

rnPat (LitPatIn lit) 
  = litFVs lit		`thenRn` \ fvs ->
    returnRn (LitPatIn lit, fvs) 

rnPat (NPatIn lit) 
  = rnOverLit lit			`thenRn` \ (lit', fvs1) ->
    lookupOrigName eqClass_RDR		`thenRn` \ eq   ->	-- Needed to find equality on pattern
    returnRn (NPatIn lit', fvs1 `addOneFV` eq)

rnPat (NPlusKPatIn name lit minus)
  = rnOverLit lit			`thenRn` \ (lit', fvs) ->
    lookupOrigName ordClass_RDR		`thenRn` \ ord ->
    lookupBndrRn name			`thenRn` \ name' ->
    lookupOccRn minus			`thenRn` \ minus' ->
    returnRn (NPlusKPatIn name' lit' minus', fvs `addOneFV` ord `addOneFV` minus')

rnPat (LazyPatIn pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    returnRn (LazyPatIn pat', fvs)

rnPat (AsPatIn name pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    lookupBndrRn name	`thenRn` \ vname ->
    returnRn (AsPatIn vname pat', fvs)

rnPat (ConPatIn con pats)
  = lookupOccRn con		`thenRn` \ con' ->
    mapFvRn rnPat pats  	`thenRn` \ (patslist, fvs) ->
    returnRn (ConPatIn con' patslist, fvs `addOneFV` con')

rnPat (ConOpPatIn pat1 con _ pat2)
  = rnPat pat1		`thenRn` \ (pat1', fvs1) ->
    lookupOccRn con	`thenRn` \ con' ->
    rnPat pat2		`thenRn` \ (pat2', fvs2) ->

    getModeRn		`thenRn` \ mode ->
	-- See comments with rnExpr (OpApp ...)
    (case mode of
	InterfaceMode -> returnRn (ConOpPatIn pat1' con' defaultFixity pat2')
	SourceMode    -> lookupFixityRn con'	`thenRn` \ fixity ->
			 mkConOpPatRn pat1' con' fixity pat2'
    )								`thenRn` \ pat' ->
    returnRn (pat', fvs1 `plusFV` fvs2 `addOneFV` con')

rnPat (ParPatIn pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    returnRn (ParPatIn pat', fvs)

rnPat (ListPatIn pats)
  = mapFvRn rnPat pats			`thenRn` \ (patslist, fvs) ->
    returnRn (ListPatIn patslist, fvs `addOneFV` listTyCon_name)

rnPat (TuplePatIn pats boxed)
  = mapFvRn rnPat pats					   `thenRn` \ (patslist, fvs) ->
    returnRn (TuplePatIn patslist boxed, fvs `addOneFV` tycon_name)
  where
    tycon_name = tupleTyCon_name boxed (length pats)

rnPat (RecPatIn con rpats)
  = lookupOccRn con 	`thenRn` \ con' ->
    rnRpats rpats	`thenRn` \ (rpats', fvs) ->
    returnRn (RecPatIn con' rpats', fvs `addOneFV` con')
rnPat (TypePatIn name) =
    (rnHsTypeFVs (text "type pattern") name) `thenRn` \ (name', fvs) ->
    returnRn (TypePatIn name', fvs)
\end{code}

************************************************************************
*									*
\subsection{Match}
*									*
************************************************************************

\begin{code}
rnMatch :: RdrNameMatch -> RnMS (RenamedMatch, FreeVars)

rnMatch match@(Match _ pats maybe_rhs_sig grhss)
  = pushSrcLocRn (getMatchLoc match)	$

	-- Find the universally quantified type variables
	-- in the pattern type signatures
    getLocalNameEnv			`thenRn` \ name_env ->
    let
	tyvars_in_sigs = rhs_sig_tyvars `unionLists` tyvars_in_pats
	rhs_sig_tyvars = case maybe_rhs_sig of
				Nothing -> []
				Just ty -> extractHsTyRdrTyVars ty
	tyvars_in_pats = extractPatsTyVars pats
	forall_tyvars  = filter (not . (`elemFM` name_env)) tyvars_in_sigs
	doc_sig        = text "a pattern type-signature"
	doc_pats       = text "in a pattern match"
    in
    bindNakedTyVarsFVRn doc_sig forall_tyvars	$ \ sig_tyvars ->

	-- Note that we do a single bindLocalsRn for all the
	-- matches together, so that we spot the repeated variable in
	--	f x x = 1
    bindLocalsFVRn doc_pats (collectPatsBinders pats) $ \ new_binders ->

    mapFvRn rnPat pats			`thenRn` \ (pats', pat_fvs) ->
    rnGRHSs grhss			`thenRn` \ (grhss', grhss_fvs) ->
    doptRn Opt_GlasgowExts		`thenRn` \ opt_GlasgowExts ->
    (case maybe_rhs_sig of
	Nothing -> returnRn (Nothing, emptyFVs)
	Just ty | opt_GlasgowExts -> rnHsTypeFVs doc_sig ty	`thenRn` \ (ty', ty_fvs) ->
				     returnRn (Just ty', ty_fvs)
		| otherwise	  -> addErrRn (patSigErr ty)	`thenRn_`
				     returnRn (Nothing, emptyFVs)
    )					`thenRn` \ (maybe_rhs_sig', ty_fvs) ->

    let
	binder_set     = mkNameSet new_binders
	unused_binders = nameSetToList (binder_set `minusNameSet` grhss_fvs)
	all_fvs	       = grhss_fvs `plusFV` pat_fvs `plusFV` ty_fvs
    in
    warnUnusedMatches unused_binders		`thenRn_`
    
    returnRn (Match sig_tyvars pats' maybe_rhs_sig' grhss', all_fvs)
	-- The bindLocals and bindTyVars will remove the bound FVs
\end{code}

%************************************************************************
%*									*
\subsubsection{Guarded right-hand sides (GRHSs)}
%*									*
%************************************************************************

\begin{code}
rnGRHSs :: RdrNameGRHSs -> RnMS (RenamedGRHSs, FreeVars)

rnGRHSs (GRHSs grhss binds maybe_ty)
  = ASSERT( not (maybeToBool maybe_ty) )
    rnBinds binds		$ \ binds' ->
    mapFvRn rnGRHS grhss	`thenRn` \ (grhss', fvGRHSs) ->
    returnRn (GRHSs grhss' binds' Nothing, fvGRHSs)

rnGRHS (GRHS guarded locn)
  = doptRn Opt_GlasgowExts		`thenRn` \ opt_GlasgowExts ->
    pushSrcLocRn locn $		    
    (if not (opt_GlasgowExts || is_standard_guard guarded) then
		addWarnRn (nonStdGuardErr guarded)
     else
		returnRn ()
    )		`thenRn_`

    rnStmts rnExpr guarded	`thenRn` \ ((_, guarded'), fvs) ->
    returnRn (GRHS guarded' locn, fvs)
  where
	-- Standard Haskell 1.4 guards are just a single boolean
	-- expression, rather than a list of qualifiers as in the
	-- Glasgow extension
    is_standard_guard [ExprStmt _ _]                = True
    is_standard_guard [GuardStmt _ _, ExprStmt _ _] = True
    is_standard_guard other	      		    = False
\end{code}

%************************************************************************
%*									*
\subsubsection{Expressions}
%*									*
%************************************************************************

\begin{code}
rnExprs :: [RdrNameHsExpr] -> RnMS ([RenamedHsExpr], FreeVars)
rnExprs ls = rnExprs' ls emptyUniqSet
 where
  rnExprs' [] acc = returnRn ([], acc)
  rnExprs' (expr:exprs) acc
   = rnExpr expr 	        `thenRn` \ (expr', fvExpr) ->

	-- Now we do a "seq" on the free vars because typically it's small
	-- or empty, especially in very long lists of constants
    let
	acc' = acc `plusFV` fvExpr
    in
    (grubby_seqNameSet acc' rnExprs') exprs acc'	`thenRn` \ (exprs', fvExprs) ->
    returnRn (expr':exprs', fvExprs)

-- Grubby little function to do "seq" on namesets; replace by proper seq when GHC can do seq
grubby_seqNameSet ns result | isNullUFM ns = result
			    | otherwise    = result
\end{code}

Variables. We look up the variable and return the resulting name. 

\begin{code}
rnExpr :: RdrNameHsExpr -> RnMS (RenamedHsExpr, FreeVars)

rnExpr (HsVar v)
  = lookupOccRn v	`thenRn` \ name ->
    if name `hasKey` assertIdKey then
	-- We expand it to (GHCerr.assert__ location)
        mkAssertExpr
    else
        -- The normal case
       returnRn (HsVar name, unitFV name)

rnExpr (HsIPVar v)
  = newIPName v			`thenRn` \ name ->
    returnRn (HsIPVar name, emptyFVs)

rnExpr (HsLit lit) 
  = litFVs lit		`thenRn` \ fvs -> 
    returnRn (HsLit lit, fvs)

rnExpr (HsOverLit lit) 
  = rnOverLit lit		`thenRn` \ (lit', fvs) ->
    returnRn (HsOverLit lit', fvs)

rnExpr (HsLam match)
  = rnMatch match	`thenRn` \ (match', fvMatch) ->
    returnRn (HsLam match', fvMatch)

rnExpr (HsApp fun arg)
  = rnExpr fun		`thenRn` \ (fun',fvFun) ->
    rnExpr arg		`thenRn` \ (arg',fvArg) ->
    returnRn (HsApp fun' arg', fvFun `plusFV` fvArg)

rnExpr (OpApp e1 op _ e2) 
  = rnExpr e1				`thenRn` \ (e1', fv_e1) ->
    rnExpr e2				`thenRn` \ (e2', fv_e2) ->
    rnExpr op				`thenRn` \ (op'@(HsVar op_name), fv_op) ->

	-- Deal with fixity
	-- When renaming code synthesised from "deriving" declarations
	-- we're in Interface mode, and we should ignore fixity; assume
	-- that the deriving code generator got the association correct
	-- Don't even look up the fixity when in interface mode
    getModeRn				`thenRn` \ mode -> 
    (case mode of
	SourceMode    -> lookupFixityRn op_name		`thenRn` \ fixity ->
			 mkOpAppRn e1' op' fixity e2'
	InterfaceMode -> returnRn (OpApp e1' op' defaultFixity e2')
    )					`thenRn` \ final_e -> 

    returnRn (final_e,
	      fv_e1 `plusFV` fv_op `plusFV` fv_e2)

rnExpr (NegApp e n)
  = rnExpr e			`thenRn` \ (e', fv_e) ->
    lookupOrigName negate_RDR	`thenRn` \ neg ->
    mkNegAppRn e' neg		`thenRn` \ final_e ->
    returnRn (final_e, fv_e `addOneFV` neg)

rnExpr (HsPar e)
  = rnExpr e 		`thenRn` \ (e', fvs_e) ->
    returnRn (HsPar e', fvs_e)

rnExpr section@(SectionL expr op)
  = rnExpr expr	 				`thenRn` \ (expr', fvs_expr) ->
    rnExpr op	 				`thenRn` \ (op', fvs_op) ->
    checkSectionPrec "left" section op' expr'	`thenRn_`
    returnRn (SectionL expr' op', fvs_op `plusFV` fvs_expr)

rnExpr section@(SectionR op expr)
  = rnExpr op	 				`thenRn` \ (op',   fvs_op) ->
    rnExpr expr	 				`thenRn` \ (expr', fvs_expr) ->
    checkSectionPrec "right" section op' expr'	`thenRn_`
    returnRn (SectionR op' expr', fvs_op `plusFV` fvs_expr)

rnExpr (HsCCall fun args may_gc is_casm fake_result_ty)
	-- Check out the comment on RnIfaces.getNonWiredDataDecl about ccalls
  = lookupOrigNames [cCallableClass_RDR, 
			  cReturnableClass_RDR, 
			  ioDataCon_RDR]	`thenRn` \ implicit_fvs ->
    rnExprs args				`thenRn` \ (args', fvs_args) ->
    returnRn (HsCCall fun args' may_gc is_casm fake_result_ty, 
	      fvs_args `plusFV` implicit_fvs)

rnExpr (HsSCC lbl expr)
  = rnExpr expr	 	`thenRn` \ (expr', fvs_expr) ->
    returnRn (HsSCC lbl expr', fvs_expr)

rnExpr (HsCase expr ms src_loc)
  = pushSrcLocRn src_loc $
    rnExpr expr		 	`thenRn` \ (new_expr, e_fvs) ->
    mapFvRn rnMatch ms		`thenRn` \ (new_ms, ms_fvs) ->
    returnRn (HsCase new_expr new_ms src_loc, e_fvs `plusFV` ms_fvs)

rnExpr (HsLet binds expr)
  = rnBinds binds		$ \ binds' ->
    rnExpr expr			 `thenRn` \ (expr',fvExpr) ->
    returnRn (HsLet binds' expr', fvExpr)

rnExpr (HsWith expr binds)
  = rnExpr expr			`thenRn` \ (expr',fvExpr) ->
    rnIPBinds binds		`thenRn` \ (binds',fvBinds) ->
    returnRn (HsWith expr' binds', fvExpr `plusFV` fvBinds)

rnExpr e@(HsDo do_or_lc stmts src_loc)
  = pushSrcLocRn src_loc $
    lookupOrigNames implicit_rdr_names	`thenRn` \ implicit_fvs ->
    rnStmts rnExpr stmts		`thenRn` \ ((_, stmts'), fvs) ->
	-- check the statement list ends in an expression
    case last stmts' of {
	ExprStmt _ _ -> returnRn () ;
	ReturnStmt _ -> returnRn () ;	-- for list comprehensions
	_            -> addErrRn (doStmtListErr e)
    }					`thenRn_`
    returnRn (HsDo do_or_lc stmts' src_loc, fvs `plusFV` implicit_fvs)
  where
    implicit_rdr_names = [foldr_RDR, build_RDR, monadClass_RDR]
	-- Monad stuff should not be necessary for a list comprehension
	-- but the typechecker looks up the bind and return Ids anyway
	-- Oh well.


rnExpr (ExplicitList exps)
  = rnExprs exps		 	`thenRn` \ (exps', fvs) ->
    returnRn  (ExplicitList exps', fvs `addOneFV` listTyCon_name)

rnExpr (ExplicitTuple exps boxity)
  = rnExprs exps	 			`thenRn` \ (exps', fvs) ->
    returnRn (ExplicitTuple exps' boxity, fvs `addOneFV` tycon_name)
  where
    tycon_name = tupleTyCon_name boxity (length exps)

rnExpr (RecordCon con_id rbinds)
  = lookupOccRn con_id 			`thenRn` \ conname ->
    rnRbinds "construction" rbinds	`thenRn` \ (rbinds', fvRbinds) ->
    returnRn (RecordCon conname rbinds', fvRbinds `addOneFV` conname)

rnExpr (RecordUpd expr rbinds)
  = rnExpr expr			`thenRn` \ (expr', fvExpr) ->
    rnRbinds "update" rbinds	`thenRn` \ (rbinds', fvRbinds) ->
    returnRn (RecordUpd expr' rbinds', fvExpr `plusFV` fvRbinds)

rnExpr (ExprWithTySig expr pty)
  = rnExpr expr			 			   `thenRn` \ (expr', fvExpr) ->
    rnHsTypeFVs (text "an expression type signature") pty  `thenRn` \ (pty', fvTy) ->
    returnRn (ExprWithTySig expr' pty', fvExpr `plusFV` fvTy)

rnExpr (HsIf p b1 b2 src_loc)
  = pushSrcLocRn src_loc $
    rnExpr p		`thenRn` \ (p', fvP) ->
    rnExpr b1		`thenRn` \ (b1', fvB1) ->
    rnExpr b2		`thenRn` \ (b2', fvB2) ->
    returnRn (HsIf p' b1' b2' src_loc, plusFVs [fvP, fvB1, fvB2])

rnExpr (HsType a)
  = rnHsTypeFVs doc a	`thenRn` \ (t, fvT) -> 
    returnRn (HsType t, fvT)
  where 
    doc = text "renaming a type pattern"

rnExpr (ArithSeqIn seq)
  = lookupOrigName enumClass_RDR	`thenRn` \ enum ->
    rn_seq seq	 			`thenRn` \ (new_seq, fvs) ->
    returnRn (ArithSeqIn new_seq, fvs `addOneFV` enum)
  where
    rn_seq (From expr)
     = rnExpr expr 	`thenRn` \ (expr', fvExpr) ->
       returnRn (From expr', fvExpr)

    rn_seq (FromThen expr1 expr2)
     = rnExpr expr1 	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       returnRn (FromThen expr1' expr2', fvExpr1 `plusFV` fvExpr2)

    rn_seq (FromTo expr1 expr2)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       returnRn (FromTo expr1' expr2', fvExpr1 `plusFV` fvExpr2)

    rn_seq (FromThenTo expr1 expr2 expr3)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       rnExpr expr3	`thenRn` \ (expr3', fvExpr3) ->
       returnRn (FromThenTo expr1' expr2' expr3',
		  plusFVs [fvExpr1, fvExpr2, fvExpr3])
\end{code}

These three are pattern syntax appearing in expressions.
Since all the symbols are reservedops we can simply reject them.
We return a (bogus) EWildPat in each case.

\begin{code}
rnExpr e@EWildPat = addErrRn (patSynErr e)	`thenRn_`
		    returnRn (EWildPat, emptyFVs)

rnExpr e@(EAsPat _ _) = addErrRn (patSynErr e)	`thenRn_`
		        returnRn (EWildPat, emptyFVs)

rnExpr e@(ELazyPat _) = addErrRn (patSynErr e)	`thenRn_`
		        returnRn (EWildPat, emptyFVs)
\end{code}



%************************************************************************
%*									*
\subsubsection{@Rbinds@s and @Rpats@s: in record expressions}
%*									*
%************************************************************************

\begin{code}
rnRbinds str rbinds 
  = mapRn_ field_dup_err dup_fields	`thenRn_`
    mapFvRn rn_rbind rbinds		`thenRn` \ (rbinds', fvRbind) ->
    returnRn (rbinds', fvRbind)
  where
    (_, dup_fields) = removeDups compare [ f | (f,_,_) <- rbinds ]

    field_dup_err dups = addErrRn (dupFieldErr str dups)

    rn_rbind (field, expr, pun)
      = lookupGlobalOccRn field	`thenRn` \ fieldname ->
	rnExpr expr		`thenRn` \ (expr', fvExpr) ->
	returnRn ((fieldname, expr', pun), fvExpr `addOneFV` fieldname)

rnRpats rpats
  = mapRn_ field_dup_err dup_fields 	`thenRn_`
    mapFvRn rn_rpat rpats		`thenRn` \ (rpats', fvs) ->
    returnRn (rpats', fvs)
  where
    (_, dup_fields) = removeDups compare [ f | (f,_,_) <- rpats ]

    field_dup_err dups = addErrRn (dupFieldErr "pattern" dups)

    rn_rpat (field, pat, pun)
      = lookupGlobalOccRn field	`thenRn` \ fieldname ->
	rnPat pat		`thenRn` \ (pat', fvs) ->
	returnRn ((fieldname, pat', pun), fvs `addOneFV` fieldname)
\end{code}

%************************************************************************
%*									*
\subsubsection{@rnIPBinds@s: in implicit parameter bindings}		*
%*									*
%************************************************************************

\begin{code}
rnIPBinds [] = returnRn ([], emptyFVs)
rnIPBinds ((n, expr) : binds)
  = newIPName n			`thenRn` \ name ->
    rnExpr expr			`thenRn` \ (expr',fvExpr) ->
    rnIPBinds binds		`thenRn` \ (binds',fvBinds) ->
    returnRn ((name, expr') : binds', fvExpr `plusFV` fvBinds)

\end{code}

%************************************************************************
%*									*
\subsubsection{@Stmt@s: in @do@ expressions}
%*									*
%************************************************************************

Note that although some bound vars may appear in the free var set for
the first qual, these will eventually be removed by the caller. For
example, if we have @[p | r <- s, q <- r, p <- q]@, when doing
@[q <- r, p <- q]@, the free var set for @q <- r@ will
be @{r}@, and the free var set for the entire Quals will be @{r}@. This
@r@ will be removed only when we finally return from examining all the
Quals.

\begin{code}
type RnExprTy = RdrNameHsExpr -> RnMS (RenamedHsExpr, FreeVars)

rnStmts :: RnExprTy
	-> [RdrNameStmt]
	-> RnMS (([Name], [RenamedStmt]), FreeVars)

rnStmts rn_expr []
  = returnRn (([], []), emptyFVs)

rnStmts rn_expr (stmt:stmts)
  = getLocalNameEnv 		`thenRn` \ name_env ->
    rnStmt rn_expr stmt				$ \ stmt' ->
    rnStmts rn_expr stmts			`thenRn` \ ((binders, stmts'), fvs) ->
    returnRn ((binders, stmt' : stmts'), fvs)

rnStmt :: RnExprTy -> RdrNameStmt
       -> (RenamedStmt -> RnMS (([Name], a), FreeVars))
       -> RnMS (([Name], a), FreeVars)
-- Because of mutual recursion we have to pass in rnExpr.

rnStmt rn_expr (ParStmt stmtss) thing_inside
  = mapFvRn (rnStmts rn_expr) stmtss	`thenRn` \ (bndrstmtss, fv_stmtss) ->
    let (binderss, stmtss') = unzip bndrstmtss
	checkBndrs all_bndrs bndrs
	  = checkRn (null (intersectBy eqOcc all_bndrs bndrs)) err `thenRn_`
	    returnRn (bndrs ++ all_bndrs)
	eqOcc n1 n2 = nameOccName n1 == nameOccName n2
	err = text "duplicate binding in parallel list comprehension"
    in
    foldlRn checkBndrs [] binderss	`thenRn` \ binders ->
    bindLocalNamesFV binders		$
    thing_inside (ParStmtOut bndrstmtss)`thenRn` \ ((rest_bndrs, result), fv_rest) ->
    returnRn ((rest_bndrs ++ binders, result), fv_stmtss `plusFV` fv_rest)

rnStmt rn_expr (BindStmt pat expr src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rn_expr expr				`thenRn` \ (expr', fv_expr) ->
    bindLocalsFVRn doc binders			$ \ new_binders ->
    rnPat pat					`thenRn` \ (pat', fv_pat) ->
    thing_inside (BindStmt pat' expr' src_loc)	`thenRn` \ ((rest_binders, result), fvs) ->
    -- ZZ is shadowing handled correctly?
    returnRn ((rest_binders ++ new_binders, result),
	      fv_expr `plusFV` fvs `plusFV` fv_pat)
  where
    binders = collectPatBinders pat
    doc = text "a pattern in do binding" 

rnStmt rn_expr (ExprStmt expr src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rn_expr expr 				`thenRn` \ (expr', fv_expr) ->
    thing_inside (ExprStmt expr' src_loc)	`thenRn` \ (result, fvs) ->
    returnRn (result, fv_expr `plusFV` fvs)

rnStmt rn_expr (GuardStmt expr src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rn_expr expr 				`thenRn` \ (expr', fv_expr) ->
    thing_inside (GuardStmt expr' src_loc)	`thenRn` \ (result, fvs) ->
    returnRn (result, fv_expr `plusFV` fvs)

rnStmt rn_expr (ReturnStmt expr) thing_inside
  = rn_expr expr				`thenRn` \ (expr', fv_expr) ->
    thing_inside (ReturnStmt expr')		`thenRn` \ (result, fvs) ->
    returnRn (result, fv_expr `plusFV` fvs)

rnStmt rn_expr (LetStmt binds) thing_inside
  = rnBinds binds				$ \ binds' ->
    thing_inside (LetStmt binds')

\end{code}

%************************************************************************
%*									*
\subsubsection{Precedence Parsing}
%*									*
%************************************************************************

@mkOpAppRn@ deals with operator fixities.  The argument expressions
are assumed to be already correctly arranged.  It needs the fixities
recorded in the OpApp nodes, because fixity info applies to the things
the programmer actually wrote, so you can't find it out from the Name.

Furthermore, the second argument is guaranteed not to be another
operator application.  Why? Because the parser parses all
operator appications left-associatively, EXCEPT negation, which
we need to handle specially.

\begin{code}
mkOpAppRn :: RenamedHsExpr			-- Left operand; already rearranged
	  -> RenamedHsExpr -> Fixity 		-- Operator and fixity
	  -> RenamedHsExpr			-- Right operand (not an OpApp, but might
						-- be a NegApp)
	  -> RnMS RenamedHsExpr

---------------------------
-- (e11 `op1` e12) `op2` e2
mkOpAppRn e1@(OpApp e11 op1 fix1 e12) op2 fix2 e2
  | nofix_error
  = addErrRn (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenRn_`
    returnRn (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn e12 op2 fix2 e2		`thenRn` \ new_e ->
    returnRn (OpApp e11 op1 fix1 new_e)
  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

---------------------------
--	(- neg_arg) `op` e2
mkOpAppRn e1@(NegApp neg_arg neg_op) op2 fix2 e2
  | nofix_error
  = addErrRn (precParseErr (pp_prefix_minus,negateFixity) (ppr_op op2,fix2))	`thenRn_`
    returnRn (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn neg_arg op2 fix2 e2	`thenRn` \ new_e ->
    returnRn (NegApp new_e neg_op)
  where
    (nofix_error, associate_right) = compareFixity negateFixity fix2

---------------------------
--	e1 `op` - neg_arg
mkOpAppRn e1 op1 fix1 e2@(NegApp neg_arg neg_op)	-- NegApp can occur on the right
  | not associate_right					-- We *want* right association
  = addErrRn (precParseErr (ppr_op op1, fix1) (pp_prefix_minus, negateFixity))	`thenRn_`
    returnRn (OpApp e1 op1 fix1 e2)
  where
    (_, associate_right) = compareFixity fix1 negateFixity

---------------------------
--	Default case
mkOpAppRn e1 op fix e2 			-- Default case, no rearrangment
  = ASSERT2( right_op_ok fix e2,
	     ppr e1 $$ text "---" $$ ppr op $$ text "---" $$ ppr fix $$ text "---" $$ ppr e2
    )
    returnRn (OpApp e1 op fix e2)

-- Parser left-associates everything, but 
-- derived instances may have correctly-associated things to
-- in the right operarand.  So we just check that the right operand is OK
right_op_ok fix1 (OpApp _ _ fix2 _)
  = not error_please && associate_right
  where
    (error_please, associate_right) = compareFixity fix1 fix2
right_op_ok fix1 other
  = True

-- Parser initially makes negation bind more tightly than any other operator
mkNegAppRn neg_arg neg_op
  = 
#ifdef DEBUG
    getModeRn			`thenRn` \ mode ->
    ASSERT( not_op_app mode neg_arg )
#endif
    returnRn (NegApp neg_arg neg_op)

not_op_app SourceMode (OpApp _ _ _ _) = False
not_op_app mode other	 	      = True
\end{code}

\begin{code}
mkConOpPatRn :: RenamedPat -> Name -> Fixity -> RenamedPat
	     -> RnMS RenamedPat

mkConOpPatRn p1@(ConOpPatIn p11 op1 fix1 p12) 
	     op2 fix2 p2
  | nofix_error
  = addErrRn (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenRn_`
    returnRn (ConOpPatIn p1 op2 fix2 p2)

  | associate_right
  = mkConOpPatRn p12 op2 fix2 p2		`thenRn` \ new_p ->
    returnRn (ConOpPatIn p11 op1 fix1 new_p)

  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

mkConOpPatRn p1 op fix p2 			-- Default case, no rearrangment
  = ASSERT( not_op_pat p2 )
    returnRn (ConOpPatIn p1 op fix p2)

not_op_pat (ConOpPatIn _ _ _ _) = False
not_op_pat other   	        = True
\end{code}

\begin{code}
checkPrecMatch :: Bool -> Name -> RenamedMatch -> RnMS ()

checkPrecMatch False fn match
  = returnRn ()

checkPrecMatch True op (Match _ (p1:p2:_) _ _)
	-- True indicates an infix lhs
  = getModeRn 		`thenRn` \ mode ->
	-- See comments with rnExpr (OpApp ...)
    case mode of
	InterfaceMode -> returnRn ()
	SourceMode    -> checkPrec op p1 False	`thenRn_`
			 checkPrec op p2 True

checkPrecMatch True op _ = panic "checkPrecMatch"

checkPrec op (ConOpPatIn _ op1 _ _) right
  = lookupFixityRn op	`thenRn` \  op_fix@(Fixity op_prec  op_dir) ->
    lookupFixityRn op1	`thenRn` \ op1_fix@(Fixity op1_prec op1_dir) ->
    let
	inf_ok = op1_prec > op_prec || 
	         (op1_prec == op_prec &&
		  (op1_dir == InfixR && op_dir == InfixR && right ||
		   op1_dir == InfixL && op_dir == InfixL && not right))

	info  = (ppr_op op,  op_fix)
	info1 = (ppr_op op1, op1_fix)
	(infol, infor) = if right then (info, info1) else (info1, info)
    in
    checkRn inf_ok (precParseErr infol infor)

checkPrec op pat right
  = returnRn ()

-- Check precedence of (arg op) or (op arg) respectively
-- If arg is itself an operator application, its precedence should
-- be higher than that of op
checkSectionPrec left_or_right section op arg
  = case arg of
	OpApp _ op fix _ -> go_for_it (ppr_op op)     fix
	NegApp _ _	 -> go_for_it pp_prefix_minus negateFixity
	other		 -> returnRn ()
  where
    HsVar op_name = op
    go_for_it pp_arg_op arg_fix@(Fixity arg_prec _)
	= lookupFixityRn op_name	`thenRn` \ op_fix@(Fixity op_prec _) ->
	  checkRn (op_prec < arg_prec)
		  (sectionPrecErr (ppr_op op_name, op_fix) (pp_arg_op, arg_fix) section)
\end{code}

Consider
\begin{verbatim}
	a `op1` b `op2` c
\end{verbatim}
@(compareFixity op1 op2)@ tells which way to arrange appication, or
whether there's an error.

\begin{code}
compareFixity :: Fixity -> Fixity
	      -> (Bool,		-- Error please
		  Bool)		-- Associate to the right: a op1 (b op2 c)
compareFixity (Fixity prec1 dir1) (Fixity prec2 dir2)
  = case prec1 `compare` prec2 of
	GT -> left
	LT -> right
	EQ -> case (dir1, dir2) of
			(InfixR, InfixR) -> right
			(InfixL, InfixL) -> left
			_		 -> error_please
  where
    right	 = (False, True)
    left         = (False, False)
    error_please = (True,  False)
\end{code}

%************************************************************************
%*									*
\subsubsection{Literals}
%*									*
%************************************************************************

When literals occur we have to make sure
that the types and classes they involve
are made available.

\begin{code}
litFVs (HsChar c)             = returnRn (unitFV charTyCon_name)
litFVs (HsCharPrim c)         = returnRn (unitFV (getName charPrimTyCon))
litFVs (HsString s)           = returnRn (mkFVs [listTyCon_name, charTyCon_name])
litFVs (HsStringPrim s)       = returnRn (unitFV (getName addrPrimTyCon))
litFVs (HsInt i)	      = returnRn (unitFV (getName intTyCon))
litFVs (HsIntPrim i)          = returnRn (unitFV (getName intPrimTyCon))
litFVs (HsFloatPrim f)        = returnRn (unitFV (getName floatPrimTyCon))
litFVs (HsDoublePrim d)       = returnRn (unitFV (getName doublePrimTyCon))
litFVs (HsLitLit l bogus_ty)  = lookupOrigName cCallableClass_RDR	`thenRn` \ cc ->   
				returnRn (unitFV cc)
litFVs lit		      = pprPanic "RnExpr.litFVs" (ppr lit)	-- HsInteger and HsRat only appear 
									-- in post-typechecker translations

rnOverLit (HsIntegral i from_integer)
  = lookupOccRn from_integer		`thenRn` \ from_integer' ->
    (if inIntRange i then
	returnRn emptyFVs
     else
	lookupOrigNames [plusInteger_RDR, timesInteger_RDR]
    )					`thenRn` \ ns ->
    returnRn (HsIntegral i from_integer', ns `addOneFV` from_integer')

rnOverLit (HsFractional i n)
  = lookupOccRn n							   `thenRn` \ n' ->
    lookupOrigNames [ratioDataCon_RDR, plusInteger_RDR, timesInteger_RDR]  `thenRn` \ ns' ->
	-- We have to make sure that the Ratio type is imported with
	-- its constructor, because literals of type Ratio t are
	-- built with that constructor.
	-- The Rational type is needed too, but that will come in
	-- when fractionalClass does.
	-- The plus/times integer operations may be needed to construct the numerator
	-- and denominator (see DsUtils.mkIntegerLit)
    returnRn (HsFractional i n', ns' `addOneFV` n')
\end{code}

%************************************************************************
%*									*
\subsubsection{Assertion utils}
%*									*
%************************************************************************

\begin{code}
mkAssertExpr :: RnMS (RenamedHsExpr, FreeVars)
mkAssertExpr =
  lookupOrigName assertErr_RDR		`thenRn` \ name ->
  getSrcLocRn    			`thenRn` \ sloc ->

    -- if we're ignoring asserts, return (\ _ e -> e)
    -- if not, return (assertError "src-loc")

  if opt_IgnoreAsserts then
    getUniqRn				`thenRn` \ uniq ->
    let
     vname = mkSysLocalName uniq SLIT("v")
     expr  = HsLam ignorePredMatch
     loc   = nameSrcLoc vname
     ignorePredMatch = Match [] [WildPatIn, VarPatIn vname] Nothing 
                             (GRHSs [GRHS [ExprStmt (HsVar vname) loc] loc]
			            EmptyBinds Nothing)
    in
    returnRn (expr, unitFV name)
  else
    let
     expr = 
          HsApp (HsVar name)
	        (HsLit (HsString (_PK_ (showSDoc (ppr sloc)))))

    in
    returnRn (expr, unitFV name)

\end{code}

%************************************************************************
%*									*
\subsubsection{Errors}
%*									*
%************************************************************************

\begin{code}
ppr_op op = quotes (ppr op)	-- Here, op can be a Name or a (Var n), where n is a Name
ppr_opfix (pp_op, fixity) = pp_op <+> brackets (ppr fixity)
pp_prefix_minus = ptext SLIT("prefix `-'")

dupFieldErr str (dup:rest)
  = hsep [ptext SLIT("duplicate field name"), 
          quotes (ppr dup),
	  ptext SLIT("in record"), text str]

precParseErr op1 op2 
  = hang (ptext SLIT("precedence parsing error"))
      4 (hsep [ptext SLIT("cannot mix"), ppr_opfix op1, ptext SLIT("and"), 
	       ppr_opfix op2,
	       ptext SLIT("in the same infix expression")])

sectionPrecErr op arg_op section
 = vcat [ptext SLIT("The operator") <+> ppr_opfix op <+> ptext SLIT("of a section"),
	 nest 4 (ptext SLIT("must have lower precedence than the operand") <+> ppr_opfix arg_op),
	 nest 4 (ptext SLIT("In the section:") <+> quotes (ppr section))]

nonStdGuardErr guard
  = hang (ptext
    SLIT("accepting non-standard pattern guards (-fglasgow-exts to suppress this message)")
    ) 4 (ppr guard)

patSigErr ty
  =  (ptext SLIT("Illegal signature in pattern:") <+> ppr ty)
	$$ nest 4 (ptext SLIT("Use -fglasgow-exts to permit it"))

patSynErr e 
  = sep [ptext SLIT("Pattern syntax in expression context:"),
	 nest 4 (ppr e)]

doStmtListErr e
  = sep [ptext SLIT("`do' statements must end in expression:"),
	 nest 4 (ppr e)]
\end{code}
