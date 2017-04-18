# frozen_string_literal: true
require 'csv'

class ProjectsController < ApplicationController
  include CurrentProject

  skip_before_action :require_project, only: [:index, :new, :create]

  PUBLIC = [:index, :show, :deploy_group_versions].freeze
  before_action :authorize_project_admin!, except: PUBLIC
  before_action :authorize_admin!, except: PUBLIC + [:edit, :update]

  helper_method :project

  alias_method :project, :current_project

  def index
    respond_to do |format|
      format.html do
        @projects = projects_for_user.alphabetical
      end

      format.json do
        projects = Project.ordered_for_user(current_user).all
        render json: { projects: projects_as_json(projects) }
      end

      format.csv do
        datetime = Time.now.strftime "%Y-%m-%d_%H-%M"
        send_data projects_as_csv(Project.all), type: :csv, filename: "Projects_#{datetime}.csv"
      end
    end
  end

  def new
    @project = Project.new
    @project.current_user = current_user
    @project.stages.build(name: "Production")
  end

  def create
    @project = Project.new(project_params)
    @project.current_user = current_user

    if @project.save
      if Rails.application.config.samson.project_created_email
        ProjectMailer.created_email(@current_user, @project).deliver_later
      end
      redirect_to @project
      Rails.logger.info("#{@current_user.name_and_email} created a new project #{@project.to_param}")
    else
      render :new
    end
  end

  def show
    respond_to do |format|
      format.html { @stages = project.stages }
      format.json { render json: project.to_json(except: [:token, :deleted_at]) }
    end
  end

  def edit
  end

  def update
    if project.update_attributes(project_params)
      redirect_to project
    else
      render :edit
    end
  end

  def deploy_group_versions
    before = params[:before] ? Time.parse(params[:before]) : Time.now
    deploy_group_versions = project.last_deploy_by_group(before).each_with_object({}) do |(id, deploy), hash|
      hash[id] = deploy.as_json(methods: :url)
    end
    render json: deploy_group_versions
  end

  protected

  def project_params
    params.require(:project).permit(
      *[
        :name,
        :repository_url,
        :description,
        :owner,
        :permalink,
        :release_branch,
        :release_source,
        :docker_release_branch,
        :include_new_deploy_groups,
        :dashboard,
      ] + Samson::Hooks.fire(:project_permitted_params)
    )
  end

  def projects_for_user
    if ids = current_user.starred_project_ids.presence
      Project.where(id: ids)
    else
      Project.limit(9).order(id: :desc) # 3 or 1 column layout depending on size
    end
  end

  # Overriding require_project from CurrentProject
  def require_project
    @project = (Project.find_by_param!(params[:id]) if params[:id])
  end

  def last_deploy_for(project)
    @projects_last_deployed_at ||= Deploy.successful.
      last_deploys_for_projects.
      includes(:project, job: :user).
      index_by(&:project_id)

    @projects_last_deployed_at[project.id]
  end

  # Renders a collection of projects as an array of Hashes, with the
  # intention that #to_json be called on the result
  def projects_as_json(projects)
    projects.map do |project|
      json = project.as_json
      last_deploy = last_deploy_for(project)
      json['last_deployed_at'] = last_deploy&.created_at
      json['last_deployed_by'] = last_deploy&.user&.email
      json['last_deploy_url'] = last_deploy&.url
      json
    end
  end

  # Renders a collection of projects into a CSV file
  def projects_as_csv(projects)
    CSV.generate do |csv|
      header = ProjectSerializer.csv_header
      header << 'Last Deploy At'
      header << 'Last Deploy By'
      header << 'Last Deploy URL'
      csv << header

      projects.each do |project|
        line = ProjectSerializer.new(project).csv_line
        last_deploy = last_deploy_for(project)
        line << last_deploy&.created_at
        line << last_deploy&.user&.email
        line << last_deploy&.url
        csv << line
      end
    end
  end
end
