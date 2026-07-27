# Coerce the values a browser submitted for a .scad's Customizer parameters against the schema the
# sidecar derived for that same source — and REFUSE what will not coerce.
#
# WHY THIS EXISTS, and why it must not be "simplified" back to a pass-through: a garbage parameter
# value renders SUCCESSFULLY. Observed against the real sidecar, not reasoned — `{"cols": "))("}`
# comes back 200 with the DEFAULT geometry, because OpenSCAD's parameterSet silently ignores a value
# it cannot parse. So without this, a user's typo yields a default-sized model, saved into their
# library, with no feedback anywhere. Silent wrong output is the failure mode this codebase treats as
# worst, so every submitted value is checked against its DECLARED type and anything that will not
# coerce raises instead of travelling on.
#
# The types are schema.py's normalized set — int / float / bool / vector / enum / str — and a param
# carrying `choices` is an enum whatever its type says (schema.py's TRAP 3).
#
# What this deliberately does NOT do: enforce min/max. Those are hints the form renders as input
# attributes; OpenSCAD HONORS an out-of-range number rather than ignoring it, so an out-of-range
# value is not the silent-default failure this class exists to stop — refusing it would only add
# false rejections.
class OpenscadParams
  # A CLIENT condition: the submitted value is wrong, not the deployment. Callers turn it into a 422
  # or a form-level alert, never a 500.
  class Invalid < StandardError; end

  # Deliberately an allowlist rather than ActiveModel::Type::Boolean, which maps EVERYTHING outside
  # its false-list to true — so garbage would silently become `true`, the exact shape of bug here.
  BOOL_TRUE  = %w[true 1 on yes].freeze
  BOOL_FALSE = %w[false 0 off no].freeze

  # Keeps an error message (and the flash cookie that may carry it) bounded when the offending value
  # is a paste rather than a typo.
  SHOWN = 40

  # submitted:    Hash{name => scalar}, straight off the form.
  # param_groups: the sidecar's normalized groups for THIS source, or nil when they couldn't be had.
  # -> Hash{name => coerced value}, ready to post to /render. Raises Invalid.
  def self.coerce(submitted, param_groups) = new(param_groups).coerce(submitted)

  def initialize(param_groups)
    @groups = param_groups
    @declared = (param_groups || []).flat_map { |g| g["params"] || [] }.index_by { |p| p["name"].to_s }
  end

  def coerce(submitted)
    submitted = (submitted || {}).to_h
    return {} if submitted.empty?
    # Nothing submitted can be checked without a schema, and forwarding unchecked values is exactly
    # the silent-default bug above. Refuse instead of guessing.
    raise Invalid, "couldn't read this design's parameters, so the values you entered can't be checked" if @groups.nil?

    submitted.to_h { |name, value| [ name.to_s, one(name.to_s, value) ] }
  end

  private

  def one(name, value)
    spec = @declared[name]
    # The form is BUILT from this same schema, so an undeclared name cannot come from it — refusing
    # costs the UI nothing and is honest: OpenSCAD would ignore it, leaving the user with default
    # geometry and no clue why.
    raise Invalid, "#{show(name)} isn't a parameter of this design" if spec.nil?
    raise Invalid, "#{show(name)} must be a single value" unless scalar?(value)
    # TRAP 3: `choices` wins over `type` — an enum's declared type is the type of its VALUES.
    return choice(spec, value) if spec["choices"].present?

    case spec["type"].to_s
    when "bool"   then boolean(spec, value)
    when "int"    then integer(spec, value)
    when "float"  then number(spec, value)
    when "vector" then vector(spec, value)
    else value.to_s # "str", and any type a future schema.py adds: text is text.
    end
  end

  # A forged `params[cols][]=1` arrives as an Array; `.to_s` would hand OpenSCAD the inspect output.
  def scalar?(value) = value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

  # Values and LABELS stay apart (OpenSCAD's `// [10:S,20:M]` gives a NUMERIC value a human label),
  # so match on the value and hand back the DECLARED one — 10, not "10".
  def choice(spec, value)
    match = spec["choices"].find { |c| c.to_s == value.to_s }
    return match unless match.nil?

    raise Invalid, "#{name_of(spec)} must be one of #{spec["choices"].join(", ")} (got #{show(value)})"
  end

  def boolean(spec, value)
    case value.to_s.strip.downcase
    when *BOOL_TRUE  then true
    when *BOOL_FALSE then false
    else raise Invalid, "#{name_of(spec)} must be true or false (got #{show(value)})"
    end
  end

  def integer(spec, value)
    n = number(spec, value)
    raise Invalid, "#{name_of(spec)} must be a whole number (got #{show(value)})" unless (n % 1).zero?

    n.to_i
  end

  # -> Integer when the value is integral, else Float. The narrowing mirrors schema.py's `_num`,
  # which turns OpenSCAD's all-floats dump into 4 rather than 4.0 — so a value round-trips through
  # the form the way it arrived instead of growing a ".0" on every save.
  def number(spec, value)
    f = Float(value.to_s.strip, exception: false)
    # nil covers blank AND garbage; !finite? covers "1e400" -> Infinity, which would otherwise reach
    # OpenSCAD as the literal text "Infinity" and be ignored. A blank number field is refused on
    # purpose: silently falling back to the default is the failure mode, not the fix.
    raise Invalid, "#{name_of(spec)} must be a number (got #{show(value)})" if f.nil? || !f.finite?

    (f % 1).zero? ? f.to_i : f
  end

  # -> the OpenSCAD literal "[a,b,c]", ALREADY BRACKETED. render.py re-brackets a bare "10,20,30"
  # itself, but only when the value contains a comma — so a one-element vector would arrive as the
  # scalar `10`, which OpenSCAD type-mismatches and silently ignores, landing back on the default
  # geometry. Emitting the literal here means the value never depends on that heuristic (nor on the
  # sidecar having successfully derived which params ARE vectors, which it treats as best-effort).
  def vector(spec, value)
    parts = value.to_s.strip.delete_prefix("[").delete_suffix("]").split(",", -1).map(&:strip)
    if parts.empty? || parts.any?(&:empty?)
      raise Invalid, "#{name_of(spec)} must be numbers separated by commas (got #{show(value)})"
    end

    "[#{parts.map { |p| number(spec, p) }.join(",")}]"
  end

  def name_of(spec) = show(spec["name"])
  def show(value) = "“#{value.to_s.truncate(SHOWN)}”"
end
