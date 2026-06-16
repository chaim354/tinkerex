module V1
  module Maker
    class TasksController < V1::BaseController
      def index
        tasks = current_user.maker_tasks.order(:position, :created_at)
        tasks = tasks.open if ActiveModel::Type::Boolean.new.cast(params[:open])
        render json: { tasks: tasks.map { |t| task_json(t) } }
      end

      def show
        render json: task_json(current_user.maker_tasks.find(params[:id]))
      end

      def create
        task = current_user.maker_tasks.new(task_params)
        task.completed_at ||= Time.current if task.status == "done"
        task.save!
        render json: task_json(task), status: :created
      end

      def update
        task = current_user.maker_tasks.find(params[:id])
        attrs = task_params.to_h
        attrs["completed_at"] = Time.current if attrs["status"] == "done" && task.completed_at.nil?
        attrs["completed_at"] = nil if attrs["status"].present? && attrs["status"] != "done"
        task.update!(attrs)
        render json: task_json(task)
      end

      def destroy
        current_user.maker_tasks.find(params[:id]).destroy!
        head :no_content
      end

      private

      def task_params
        params.require(:task).permit(:title, :notes, :status, :position, :taskable_type, :taskable_id)
      end

      def task_json(t)
        { id: t.id, title: t.title, notes: t.notes, status: t.status, position: t.position,
          completed_at: t.completed_at, taskable_type: t.taskable_type, taskable_id: t.taskable_id,
          created_at: t.created_at, updated_at: t.updated_at }
      end
    end
  end
end
