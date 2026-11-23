module Maker
  module Material
    # ONE ROW OF THE MATERIAL ESTIMATE: a measured part (mm, with a quantity) or a refused file with
    # the reason it could not be measured. A refused row stays in the list, greyed, and counts toward
    # nothing — dropping it would make the total quietly describe fewer files than were added.
    Part = Data.define(:name, :node_id, :page, :width, :height, :qty, :reason) do
      def self.measured(name:, width:, height:, node_id: nil, page: nil, qty: 1)
        new(name:, node_id:, page:, width:, height:, qty:, reason: nil)
      end

      def self.refused(name:, reason:, node_id: nil)
        new(name:, node_id:, page: nil, width: nil, height: nil, qty: 1, reason:)
      end

      def measured? = reason.nil?

      def label = page.present? ? "#{name} · #{page}" : name

      def area = measured? ? width * height * qty : 0.0
    end
  end
end
