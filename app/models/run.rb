class Run < ActiveRecord::Base
  module Constants
    CODE_NEW_TASK = "new_task"
    CODE_UPDATE_TASK = "update_task"
    CODE_RUN_TASK = "run_task"
    CODE_UPDATE_CHECKER = "update_checker"

    STATUS_STARTING = "starting"
    STATUS_PENDING = "pending"
    STATUS_RUNNING = "running"
    STATUS_CE = "compilation error"
    STATUS_ERROR = "unknown error"
    STATUS_GRADER_ERROR = "grader error"
    STATUS_SUCCESS = "success"

    TEST_OUTCOME_TIME_LIMIT = 'tl'
    TEST_OUTCOME_MEMORY_LIMIT = 'ml'
    TEST_OUTCOME_RUNTIME_ERROR = 're'
    TEST_OUTCOME_WRONG_ANSWER = 'wa'
    TEST_OUTCOME_OK = 'ok'
    TEST_OUTCOME_GRADER_ERROR = 'ge'
  end

  include Constants

  validates :task_id, presence: true

  scope :latest_first, -> { order('created_at desc') }
  scope :earliest_first, -> { order('created_at asc') }
  scope :pending, -> { where(status: [STATUS_PENDING, STATUS_RUNNING, STATUS_STARTING]) }

  before_create do
    self.status = STATUS_PENDING if self.status.blank?
    self.message = "Pending" if self.message.blank?
  end

  belongs_to :user
  belongs_to :task

  def is_updating_run?
    self.code == CODE_UPDATE_TASK
  end

  def is_grading_run?
    self.code == CODE_RUN_TASK
  end
end
