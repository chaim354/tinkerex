# The calculator modal and the Calculations panel (2026-10-21; plan 2026-10-21-calculator-modal.md).
module CalculationsHelper
  # The panel's rows, by project: the target CalculationsController#create's stream replaces, so a
  # save from the modal lands in the panel when that project's page is the one open.
  def calculation_rows_id(project) = "calculation-rows-#{project.id}"

  # THE PAGE'S OWN PROJECT, for the save form to preselect: the project page and its children set
  # `@project`. Anything else — no project, or an ivar some other controller named the same — is nil,
  # and the form asks.
  def calculator_project_id
    @project.id if @project.is_a?(Maker::Project) && @project.persisted?
  end

  # THE KEYBOARD SHORTCUT (calculator_controller.js#shortcut), AS THE MAKER'S KEYBOARD PRINTS IT: ⌥C on
  # a Mac or an iPad, Alt+C elsewhere. The controller listens for both spellings of the one chord,
  # so a user agent read wrongly costs a label, never the shortcut. `aria-keyshortcuts` takes the
  # platform-neutral name, which is always Alt+C.
  CALCULATOR_KEYS = "Alt+C".freeze

  def calculator_shortcut
    request.user_agent.to_s.match?(/Macintosh|iPhone|iPad/) ? "⌥C" : CALCULATOR_KEYS
  end

  # WHAT THE CALCULATOR SHOWED, AGAIN: the number to ten significant digits with its unit, or for an
  # inch result saved at 1/16 or 1/32 the fraction the modal drew (`≈` when it rounds). The same
  # rules as lib/calc.js's formatNumber and formatInches, restated for the server because the panel
  # renders without running the engine; calculations_test.rb pins the shared cases.
  def calculation_result_text(calculation)
    if calculation.unit == "in" && calculation.inch_fraction
      inch_fraction_text(calculation.result, calculation.inch_fraction)
    else
      number = calculation_number(calculation.result)
      case calculation.unit
      when "" then number
      when "°" then "#{number}°"
      else "#{number} #{calculation.unit}"
      end
    end
  end

  private

  def calculation_number(value)
    text = number_with_precision(value, precision: 10, significant: true, strip_insignificant_zeros: true)
    text == "-0" ? "0" : text
  end

  def inch_fraction_text(inches, denominator)
    steps = (inches * denominator).round
    whole, rest = steps.abs.divmod(denominator)
    common = rest.gcd(denominator)
    fraction = "#{rest / common}/#{denominator / common}" unless rest.zero?
    body = [ (whole unless whole.zero? && fraction), fraction ].compact.join(" ")
    sign = steps.negative? ? "-" : ""
    exact = ((steps.to_f / denominator) - inches).abs < 1e-9
    "#{"≈ " unless exact}#{sign}#{body} in"
  end
end
