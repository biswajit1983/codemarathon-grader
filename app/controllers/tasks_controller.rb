class TasksController < ApplicationController

  before_filter :restrict_access, except: [:index]
  before_filter :authenticate_user!, only: [:index]

  def index
    @tasks = current_user.tasks
  end

  def create
    @user = User.find_by_email(params[:email])
    if @user.nil?
      render inline: {status: 1,
        message: "Invalid user email specified."}.to_json
      return
    end

    @task = @user.tasks.create(task_params)

    if @task.save
      render inline: {status: 0, message: "New task created.", task_id: @task.id}.to_json
    else
      render inline: {status: 1,
        message: "Failed to create a new task. Error: %s" % @task.errors.full_messages}.to_json
    end
  end

  def update_task
    @user = User.find_by_email(params[:email])
    if @user.nil?
      render inline: {status: 1,
        message: "Invalid user email specified."}.to_json
      return
    end

    @task = @user.tasks.find_by_id(params[:task_id])

    if @task.update_attributes(task_params)
      render inline: {status: 0, message: "Task updated.", task_id: @task.id}.to_json
    else
      render inline: {status: 1,
        message: "Failed to update task. Error: %s" % @task.errors.full_messages}.to_json
    end
  end

  private

  def task_params
    params.require(:task).permit(:name, :description, :task_type)
  end
end
