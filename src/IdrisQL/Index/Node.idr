module IdrisQL.Index.Node

import Data.List

%default total

-- The pure part of B+ tree restructuring. Splits, merges and redistribution
-- all reduce to cutting an ordered list of cells in two (leaf) or three
-- (internal, where the middle cell moves up). The cuts carry proofs that no
-- cell is lost, duplicated or reordered.

||| `xs` cut into a prefix and a suffix.
public export
record Cut (a : Type) (xs : List a) where
  constructor MkCut
  left : List a
  right : List a
  0 preserves : left ++ right = xs

||| Cut after the shortest prefix whose weight reaches `target`. When `xs`
||| has at least two elements the suffix is non-empty (`cutRightNonEmpty`).
public export
cutAt : (weight : a -> Nat) -> (target : Nat) -> (xs : List a) -> Cut a xs
cutAt weight target [] = MkCut [] [] Refl
cutAt weight target [x] = MkCut [x] [] Refl
cutAt weight target [x, y] = MkCut [x] [y] Refl
cutAt weight target (x :: y :: z :: rest) =
  if weight x >= target
    then MkCut [x] (y :: z :: rest) Refl
    else let c = cutAt weight (target `minus` weight x) (y :: z :: rest)
         in MkCut (x :: c.left) c.right (cong (x ::) c.preserves)

export
cutLeftNonEmpty : (weight : a -> Nat) -> (target : Nat) -> (x : a) -> (rest : List a) ->
                  NonEmpty (left (cutAt weight target (x :: rest)))
cutLeftNonEmpty weight target x [] = IsNonEmpty
cutLeftNonEmpty weight target x [y] = IsNonEmpty
cutLeftNonEmpty weight target x (y :: z :: rest) with (weight x >= target)
  _ | True = IsNonEmpty
  _ | False = IsNonEmpty

export
cutRightNonEmpty : (weight : a -> Nat) -> (target : Nat) -> (x, y : a) -> (rest : List a) ->
                   NonEmpty (right (cutAt weight target (x :: y :: rest)))
cutRightNonEmpty weight target x y [] = IsNonEmpty
cutRightNonEmpty weight target x y (z :: rest) with (weight x >= target)
  _ | True = IsNonEmpty
  _ | False = cutRightNonEmpty weight (target `minus` weight x) y z rest

||| `xs` cut around one element.
public export
record Cut3 (a : Type) (xs : List a) where
  constructor MkCut3
  left : List a
  mid : a
  right : List a
  0 preserves : left ++ mid :: right = xs

||| Cut around the first element after the prefix chosen by `cutAt`.
||| `Nothing` when `xs` has fewer than two elements.
public export
cutMiddle : (weight : a -> Nat) -> (target : Nat) -> (xs : List a) -> Maybe (Cut3 a xs)
cutMiddle weight target xs =
  case cutAt weight target xs of
    MkCut l [] _ => Nothing
    MkCut l (m :: r) prf => Just (MkCut3 l m r prf)

||| Joining two nodes and cutting the result keeps every cell of both, in
||| order. This is the statement used by redistribution.
export
0 recutPreserves : (weight : a -> Nat) -> (target : Nat) -> (xs, ys : List a) ->
                 left (cutAt weight target (xs ++ ys)) ++ right (cutAt weight target (xs ++ ys)) = xs ++ ys
recutPreserves weight target xs ys = (cutAt weight target (xs ++ ys)).preserves

||| Insert `x` so that it becomes element `i`, or the last element when `i`
||| is past the end.
public export
insertAt : (i : Nat) -> (x : a) -> List a -> List a
insertAt Z x xs = x :: xs
insertAt (S k) x [] = [x]
insertAt (S k) x (y :: ys) = y :: insertAt k x ys

export
insertAtLength : (i : Nat) -> (x : a) -> (xs : List a) -> length (insertAt i x xs) = S (length xs)
insertAtLength Z x xs = Refl
insertAtLength (S k) x [] = Refl
insertAtLength (S k) x (y :: ys) = cong S (insertAtLength k x ys)
