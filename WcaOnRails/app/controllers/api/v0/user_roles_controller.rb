# frozen_string_literal: true

class Api::V0::UserRolesController < Api::V0::ApiController
  before_action :current_user_is_authorized_for_action!, only: [:create, :update, :destroy]
  private def current_user_is_authorized_for_action!
    unless current_user.board_member? || current_user.senior_delegate?
      render json: {}, status: 401
    end
  end

  # Filters the list of roles based on the permissions of the current user.
  private def filter_roles_for_logged_in_user(roles)
    roles.select do |role|
      is_actual_role = role.is_a?(UserRole) # Eventually, all roles will be migrated to the new system,
      # till then some roles will actually be hashes.
      group = is_actual_role ? role.group : role[:group] # In future this will be group = role.group
      # hence, to reduce the number of lines to be edited in future, will be using ternary operator
      # to access the parameters of group.
      if is_actual_role ? group.is_hidden : group[:is_hidden]
        if group.group_type == UserGroup.group_types[:delegate_probation]
          current_user.can_manage_delegate_probation?
        else
          false # Don't accept any other hidden groups.
        end
      else
        true # Accept all non-hidden groups.
      end
    end
  end

  # Filters the list of roles based on given parameters.
  private def filter_roles_for_parameters(roles: [], status: nil, is_active: nil, is_group_hidden: nil)
    roles.reject do |role|
      is_actual_role = role.is_a?(UserRole) # See previous is_actual_role comment.
      # In future, the following lines will be replaced by the following:
      # (
      #   status.present? && status != role.metadata.status ||
      #   is_active.present? && is_active != role.is_active ||
      #   is_group_hidden.present? && is_group_hidden != role.group.is_hidden
      # )
      # Till then, we need to support both the old and new systems. So, we will be using ternary
      # operator to access the parameters.
      (
        (status.present? && status != (is_actual_role ? role.metadata.status : role[:metadata][:status])) ||
        (is_active.present? && is_active != (is_actual_role ? role.is_active : role[:is_active])) ||
        (is_group_hidden.present? && is_group_hidden != (is_actual_role ? role.group.is_hidden : role[:group][:is_hidden]))
      )
    end
  end

  # Returns a list of roles by user which are not yet migrated to the new system.
  private def user_roles_not_yet_in_new_system(user_id)
    user = User.find(user_id)
    roles = []

    if user.delegate_status.present?
      roles << user.delegate_role
    end

    roles.concat(user.team_roles)

    if user.admin? || user.board_member?
      roles << {
        group: {
          id: user.admin? ? 'admin' : 'board',
          name: user.admin? ? 'Admin Group' : 'Board Group',
          group_type: UserGroup.group_types[:teams_committees],
          is_hidden: false,
          is_active: true,
        },
        is_active: true,
        user: user,
        metadata: {
          status: 'member',
        },
      }
    end

    roles
  end

  # Returns a list of roles by user which are not yet migrated to the new system.
  private def group_roles_not_yet_in_new_system(group_id)
    group = UserGroup.find(group_id)
    roles = []

    if group.group_type == UserGroup.group_types[:delegate_regions]
      User.where(region_id: group.id).map do |delegate_user|
        roles << delegate_user.delegate_role
      end
    end

    roles
  end

  # Removes all pending WCA ID claims for the demoted Delegate and notifies the users.
  private def remove_pending_wca_id_claims(user)
    region_senior_delegate = user.region.senior_delegate
    user.confirmed_users_claiming_wca_id.each do |confirmed_user|
      WcaIdClaimMailer.notify_user_of_delegate_demotion(confirmed_user, user, region_senior_delegate).deliver_later
    end
    # Clear all pending WCA IDs claims for the demoted Delegate
    User.where(delegate_to_handle_wca_id_claim: user.id).update_all(delegate_id_to_handle_wca_id_claim: nil, unconfirmed_wca_id: nil)
  end

  # Returns a list of roles primarily based on userId.
  def index_for_user
    user_id = params.require(:user_id)
    roles = UserRole.where(user_id: user_id).to_a # to_a is to convert the ActiveRecord::Relation to an
    # array, so that we can append roles which are not yet migrated to the new system. This can be
    # removed once all roles are migrated to the new system.

    # Appends roles which are not yet migrated to the new system.
    roles.concat(user_roles_not_yet_in_new_system(user_id))

    # Filter the list based on the permissions of the logged in user.
    roles = filter_roles_for_logged_in_user(roles)

    # Filter the list based on the other parameters.
    roles = filter_roles_for_parameters(
      roles: roles,
      is_active: params.key?(:isActive) ? ActiveRecord::Type::Boolean.new.cast(params.require(:isActive)) : nil,
      is_group_hidden: params.key?(:isGroupHidden) ? ActiveRecord::Type::Boolean.new.cast(params.require(:isGroupHidden)) : nil,
    )

    render json: roles
  end

  # Returns a list of roles primarily based on groupId.
  def index_for_group
    group_id = params.require(:group_id)
    roles = UserRole.where(group_id: group_id).to_a # to_a is for the same reason as in index_for_user.

    # Appends roles which are not yet migrated to the new system.
    roles.concat(group_roles_not_yet_in_new_system(group_id))

    # Filter the list based on the permissions of the logged in user.
    roles = filter_roles_for_logged_in_user(roles)

    render json: roles
  end

  # Returns a list of roles primarily based on groupType.
  def index_for_group_type
    group_type = params.require(:group_type)
    group_ids = UserGroup.where(group_type: group_type).pluck(:id)
    roles = UserRole.where(group_id: group_ids).to_a # to_a is for the same reason as in index_for_user.

    # Temporary hack to support the old system roles, will be removed once all roles are
    # migrated to the new system.
    if group_type == UserGroup.group_types[:delegate_regions]
      roles.concat(User.where.not(delegate_status: nil).map(&:delegate_role))
    elsif group_type == UserGroup.group_types[:councils]
      Team.all_councils.each do |council|
        leader = council.leader
        if leader.present?
          roles << {
            id: group_type + "_" + leader.id.to_s,
            group: {
              id: group_type + "_" + council.id.to_s,
              name: council.name,
              group_type: UserGroup.group_types[:councils],
              is_hidden: false,
              is_active: true,
            },
            user: leader.user,
            metadata: {
              status: 'leader',
            },
          }
        end
      end
    end

    # Filter the list based on the permissions of the logged in user.
    roles = filter_roles_for_logged_in_user(roles)

    # Filter the list based on the other parameters.
    roles = filter_roles_for_parameters(roles: roles, status: params[:status], is_active: params[:isActive])

    render json: roles
  end

  def create
    user_id = params.require(:userId)
    group_id = params.require(:groupId)

    if group_id.include?("_") # Temporary hack to support some old system roles, will be removed once all roles are
      # migrated to the new system.
      group_type = group_id.split("_").first
      original_group_id = group_id.split("_").last
      if group_type == UserGroup.group_types[:councils]
        status = params.require(:status)
        already_existing_member = TeamMember.find_by(team_id: original_group_id, user_id: user_id, end_date: nil)
        if already_existing_member.present?
          already_existing_member.update!(end_date: Date.today)
        end
        TeamMember.create!(team_id: original_group_id, user_id: user_id, start_date: Date.today, team_leader: status == "leader", team_senior_member: status == "senior_member")
        render json: {
          success: true,
        }
      else
        render status: :unprocessable_entity, json: { error: "Invalid group type" }
      end
    else
      render status: :unprocessable_entity, json: { error: "Invalid group id" }
    end
  end

  def show
    user_id = params.require(:userId)
    is_active_role = ActiveRecord::Type::Boolean.new.cast(params.require(:isActiveRole))

    if is_active_role
      user = User.find(user_id)
      render json: {
        roleData: {
          delegateStatus: user.delegate_status,
          regionId: user.region_id,
          location: user.location,
        },
        regions: UserGroup.delegate_regions,
      }
    else
      render json: {
        roleData: {},
        regions: UserGroup.delegate_regions,
      }
    end
  end

  def update
    id = params.require(:id)

    if id == UserRole::DELEGATE_ROLE_ID
      user_id = params.require(:userId)
      delegate_status = params.require(:delegateStatus)
      region_id = params.require(:regionId)
      location = params.require(:location)

      user = User.find(user_id)
      user.update!(delegate_status: delegate_status, region_id: region_id, location: location)
      send_role_change_notification(user)

      render json: {
        success: true,
      }
    elsif id.include?("_") # Temporary hack to support some old system roles, will be removed once
      # all roles are migrated to the new system.
      group_id = params.require(:groupId)
      status = params.require(:status)
      group_type = id.split("_").first
      original_group_id = group_id.split("_").last
      if group_type == UserGroup.group_types[:councils]
        user_id = params.require(:userId)
        already_existing_member = TeamMember.find_by(team_id: original_group_id, user_id: user_id, end_date: nil)
        if already_existing_member.present?
          already_existing_member.update!(end_date: Time.now)
        end
        TeamMember.create!(team_id: original_group_id, user_id: user_id, start_date: Date.today, team_leader: status == "leader", team_senior_member: status == "senior_member")
        render json: {
          success: true,
        }
      else
        render status: :unprocessable_entity, json: { error: "Invalid group type" }
      end
    else
      render status: :unprocessable_entity, json: { error: "Invalid role id" }
    end
  end

  def destroy
    id = params.require(:id)

    if id == UserRole::DELEGATE_ROLE_ID
      user_id = params.require(:userId)

      user = User.find(user_id)
      remove_pending_wca_id_claims(user)
      user.update!(delegate_status: '', region_id: '', location: '')
      send_role_change_notification(user)

      render json: {
        success: true,
      }
    elsif id.include?("_") # Temporary hack to support some old system roles, will be removed once
      # all roles are migrated to the new system.
      group_id = params.require(:groupId)
      group_type = id.split("_").first
      original_group_id = group_id.split("_").last
      if group_type == UserGroup.group_types[:councils]
        user_id = params.require(:userId)
        already_existing_member = TeamMember.find_by(team_id: original_group_id, user_id: user_id, end_date: nil)
        if already_existing_member.present?
          already_existing_member.update!(end_date: Date.today)
        end
        render json: {
          success: true,
        }
      else
        render status: :unprocessable_entity, json: { error: "Invalid group type" }
      end
    else
      render status: :unprocessable_entity, json: { error: "Invalid role id" }
    end
  end

  private def send_role_change_notification(user)
    if user.saved_change_to_delegate_status
      if user.delegate_status
        region_id = user.region_id
      else
        region_id = user.region_id_before_last_save
      end
      region_senior_delegate = UserGroup.find_by(id: region_id).senior_delegate
      DelegateStatusChangeMailer.notify_board_and_assistants_of_delegate_status_change(
        user,
        current_user,
        region_senior_delegate,
        user.delegate_status_before_last_save,
        user.delegate_status,
      ).deliver_later
    end
  end
end
