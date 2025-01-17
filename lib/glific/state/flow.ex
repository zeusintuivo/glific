defmodule Glific.State.Flow do
  @moduledoc """
  Manage flow state and allocation to ensure we only have one user modify
  a flow at a time
  """
  require Logger
  import Ecto.Query, warn: false

  alias Glific.{
    Flows.Flow,
    Repo,
    State,
    Users.User
  }

  @doc """
  Check if there is an available flow for this user
  - If available, return the available flow
  - If none available, return error message along with name of user currently using flow
  """
  @spec get_flow(User.t(), non_neg_integer, map) :: {Flow.t(), map}
  def get_flow(user, flow_id, state) do
    organization_id = user.organization_id

    {org_state, flow} =
      State.get_state(state, organization_id)
      |> State.free_entity(:flows, user)
      |> get_org_flows(user, flow_id)

    {flow, Map.put(state, organization_id, org_state)}
  end

  @spec get_org_flows(map(), User.t(), non_neg_integer()) :: {map, Flow.t()}
  defp get_org_flows(
         %{
           flow: %{free: free, busy: busy}
         } = state,
         user,
         flow_id
       ) do
    key = {user.id, user.fingerprint}
    organization_id = user.organization_id

    [flow] =
      Flow
      |> where([f], f.organization_id == ^organization_id)
      |> where([f], f.id == ^flow_id)
      |> Repo.all(skip_organization_id: true, skip_permission: true)

    available_flow = if(Enum.member?(free, flow), do: flow, else: nil)

    cond do
      # when the requested flow is either not available in flow or if all the flows are busy
      is_nil(available_flow) || Enum.empty?(free) ->
        Repo.put_process_state(user.organization_id)
        user_name = get_user_name(state, flow)

        {state,
         {:ok,
          %{
            errors: %{
              key: "error",
              message:
                "Sorry! You cannot edit the flow right now. It is being edited by \n #{user_name}"
            }
          }}}

      # when the flow is available and user is assigned a flow
      is_struct(available_flow) ->
        {
          State.update_state(
            state,
            :flow,
            free -- [available_flow],
            Map.put(busy, key, {flow, DateTime.utc_now()})
          ),
          available_flow
        }

      true ->
        Logger.info(
          "Error fetching flow #{available_flow} for organization_id #{organization_id} for user #{user.name}"
        )

        {state,
         {:ok,
          %{
            errors: %{
              key: "error",
              message: "Something went wrong"
            }
          }}}
    end
  end

  @spec get_user_name(map(), Flow.t()) :: String.t()
  defp get_user_name(state, requested_flow) do
    %{flow: %{busy: busy}} = state

    busy
    |> Enum.reduce("", fn busy_flow, acc ->
      {key, value} = busy_flow
      {flow, _time} = value
      {user_id, _finger_print} = key
      if flow.id == requested_flow.id, do: Glific.Users.get_user!(user_id).name, else: acc
    end)
  end

  @doc false
  @spec init_state(non_neg_integer) :: map()
  def init_state(organization_id) do
    # fetch all the flows for this organization
    flows =
      Glific.Flows.Flow
      |> where([f], f.organization_id == ^organization_id)
      |> Repo.all(skip_organization_id: true, skip_permission: true)

    %{flow: %{free: flows, busy: %{}}}
  end
end
