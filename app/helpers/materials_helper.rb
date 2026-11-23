# THE MATERIAL ESTIMATE'S NUMBERS IN WORDS (tools/materials/*).
module MaterialsHelper
  SHEETS_DRAWN = 20
  SQ_IN_PER_SQ_FT = 144

  def material_area_text(mm2)
    in2 = mm2 / (Maker::Previews::Dimensions::MM_PER_INCH**2)
    text = "#{material_number(mm2 / 100.0)} cm² · #{material_number(in2)} in²"
    in2 >= SQ_IN_PER_SQ_FT ? "#{text} (#{material_number(in2 / SQ_IN_PER_SQ_FT, 2)} ft²)" : text
  end

  # Rounded, delimited, and without a trailing ".0": "250", "38.8", "1,234.5".
  def material_number(value, places = 1)
    rounded = value.round(places)
    number_with_delimiter(rounded == rounded.to_i ? rounded.to_i : rounded)
  end

  def material_stock_text(stock) = "#{recipe_num(stock.width)} × #{recipe_num(stock.height)} #{stock.unit}"

  def material_inches(width, height)
    [ width, height ].map { |mm| format("%.2f", mm / Maker::Previews::Dimensions::MM_PER_INCH) }.join(" × ")
  end

  # A label that fits inside its part on the drawing, as [text, font size in mm], or nil when the
  # part is too small to carry a readable one (its <title> still names it on hover).
  def material_sheet_label(placement, sheet_width)
    text = placement.item.label.truncate(28)
    size = [ placement.height * 0.4, placement.width / [ text.length * 0.62, 1 ].max, sheet_width / 25.0 ].min
    size >= sheet_width / 120.0 ? [ text, size.round(2) ] : nil
  end
end
