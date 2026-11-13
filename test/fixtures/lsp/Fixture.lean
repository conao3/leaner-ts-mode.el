import Lean

namespace Integration

def double (n : Nat) : Nat := n + n

theorem swap (p q : Prop) (h : p ∧ q) : q ∧ p := by
  constructor
  · exact h.2
  · exact h.1

theorem double_spec (n : Nat) : double n = n + n := by
  rfl

end Integration

#check Integration.double

set_option trace.Meta.synthInstance true in
#synth Inhabited Nat
