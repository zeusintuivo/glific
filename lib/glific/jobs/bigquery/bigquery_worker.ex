defmodule Glific.Jobs.BigQueryWorker do
  @moduledoc """
  Process the message table for each organization. Chunk number of messages
  in groups of 128 and create a bigquery Worker Job to deliver the message to
  the bigquery servers

  We centralize both the cron job and the worker job in one module
  """

  import Ecto.Query

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    priority: 0

  alias Glific.{
    Contacts.Contact,
    Jobs,
    Messages.Message,
    Partners,
    Repo
  }

  alias GoogleApi.BigQuery.{
    V2.Api.Tabledata,
    V2.Connection
  }

  @doc """
  This is called from the cron job on a regular schedule. we sweep the messages table
  and queue them up for delivery to bigquery
  """
  @spec perform_periodic(non_neg_integer) :: :ok
  def perform_periodic(organization_id) do
    Jobs.get_bigquery_jobs(organization_id)
    |> Enum.each(&perform_for_table(&1, organization_id))

    :ok
  end

  @spec perform_for_table(Jobs.BigqueryJob.t() | nil, non_neg_integer) :: :ok | nil
  defp perform_for_table(nil, _), do: nil

  defp perform_for_table(bigquery_job, organization_id) do
    table_id = bigquery_job.table_id

    max_id =
      get_table_struct(bigquery_job.table)
      |> select([m], max(m.id))
      |> where([m], m.organization_id == ^organization_id)
      |> Repo.one()

    if max_id > table_id do
      Jobs.update_bigquery_job(bigquery_job, %{table_id: max_id})
      queue_table_data(bigquery_job.table, organization_id, table_id, max_id)
    end

    :ok
  end

  @spec queue_table_data(String.t(), non_neg_integer, non_neg_integer, non_neg_integer) :: :ok
  defp queue_table_data("messages", organization_id, min_id, max_id) do
    query =
      Message
      |> where([m], m.organization_id == ^organization_id)
      |> where([m], m.id > ^min_id and m.id <= ^max_id)
      |> order_by([m], [m.inserted_at, m.id])
      |> preload([:tags, :receiver, :sender, :contact])

    Repo.all(query)
    |> Enum.reduce(
      [],
      fn row, acc ->
        [
          %{
            type: row.type,
            user_id: row.contact_id,
            message: row.body,
            inserted_at: format_date(row.inserted_at),
            sent_at: format_date(row.sent_at),
            uuid: row.uuid,
            id: row.contact_id,
            flow: row.flow,
            status: row.status,
            sender_phone: row.sender.phone,
            receiver_phone: row.receiver.phone,
            contact_phone: row.contact.phone,
            user_phone: row.contact.phone,
            tags: Enum.map(row.tags, fn tag -> %{label: tag.label} end)
          }
          | acc
        ]
      end
    )
    |> Enum.chunk_every(100)
    |> Enum.each(&make_job(&1, "messages", organization_id))
  end

  defp queue_table_data("contacts", organization_id, min_id, max_id) do
    query =
      Contact
      |> where([m], m.organization_id == ^organization_id)
      |> where([m], m.id > ^min_id and m.id <= ^max_id)
      |> order_by([m], [m.inserted_at, m.id])
      |> preload([:language, :tags, :groups])

    Repo.all(query)
    |> Enum.reduce(
      [],
      fn row, acc ->
        [
          %{
            id: row.id,
            name: row.name,
            phone: row.phone,
            provider_status: row.provider_status,
            status: row.status,
            language: row.language.label,
            optin_time: format_date(row.optin_time),
            optout_time: format_date(row.optout_time),
            last_message_at: format_date(row.last_message_at),
            inserted_at: format_date(row.inserted_at),
            fields: row.fields,
            settings: row.settings,
            groups: Enum.map(row.groups, fn group -> %{label: group.label} end),
            tags: Enum.map(row.tags, fn tag -> %{label: tag.label} end)
          }
          | acc
        ]
      end
    )
    |> Enum.chunk_every(100)
    |> Enum.each(&make_job(&1, "contacts", organization_id))
  end

  defp queue_table_data(_, _, _, _), do: nil

  @spec make_job(list(), String.t(), non_neg_integer) :: :ok | nil
  defp make_job(data, "messages", organization_id) do
    __MODULE__.new(%{organization_id: organization_id, messages: data})
    |> Oban.insert()

    :ok
  end

  defp make_job(data, "contacts", organization_id) do
    __MODULE__.new(%{organization_id: organization_id, contacts: data})
    |> Oban.insert()
  end

  defp make_job(_, _, _), do: nil

  @spec get_table_struct(String.t()) :: any()
  defp get_table_struct(table) do
    case table do
      "messages" -> Message
      "contacts" -> Contact
      _ -> ""
    end
  end

  @spec format_date(DateTime.t() | nil) :: any()
  defp format_date(nil),
    do: nil

  defp format_date(date),
    do: Timex.format!(date, "{YYYY}-{0M}-{D} 18:52:36")

  @spec token(map()) :: any()
  defp token(credentials) do
    config =
      case Jason.decode(credentials.secrets["service_account"]) do
        {:ok, config} -> config
        _ -> :error
      end

    Goth.Config.add_config(config)

    {:ok, token} =
      Goth.Token.for_scope({credentials.secrets["project_email"], credentials.keys["url"]})

    token
  end

  @doc """
  Standard perform method to use Oban worker
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, :string}
  def perform(%Oban.Job{args: %{"messages" => messages, "organization_id" => organization_id}}) do
    messages
    |> Enum.map(fn msg -> format_data_for_bigquery("messages", msg) end)
    |> make_insert_query("messages", organization_id)
  end

  def perform(%Oban.Job{args: %{"contacts" => contacts, "organization_id" => organization_id}}) do
    contacts
    |> Enum.map(fn msg -> format_data_for_bigquery("contacts", msg) end)
    |> make_insert_query("contacts", organization_id)
  end

  @spec format_data_for_bigquery(String.t(), map()) :: map()
  defp format_data_for_bigquery("messages", msg) do
    %{
      json: %{
        id: msg["id"],
        body: msg["message"],
        type: msg["type"],
        flow: msg["flow"],
        inserted_at: msg["inserted_at"],
        sent_at: msg["sent_at"],
        uuid: msg["uuid"],
        status: msg["status"],
        sender_phone: msg["sender_phone"],
        receiver_phone: msg["receiver_phone"],
        contact_phone: msg["contact_phone"],
        user_phone: msg["user_phone"],
        tags: msg["tags"]
      }
    }
  end

  defp format_data_for_bigquery("contacts", contact) do
    %{
      json: %{
        id: contact["id"],
        name: contact["name"],
        phone: contact["phone"],
        provider_status: contact["provider_status"],
        status: contact["status"],
        language: contact["language"],
        optin_time: contact["optin_time"],
        optout_time: contact["optout_time"],
        last_message_at: contact["last_message_at"],
        inserted_at: contact["inserted_at"],
        fields: contact["fields"],
        settings: contact["settings"],
        groups: contact["groups"],
        tags: contact["tags"]
      }
    }
  end

  defp format_data_for_bigquery(_, _), do: %{}

  @spec make_insert_query(list(), String.t(), non_neg_integer) :: :ok
  defp make_insert_query(data, table, organization_id) do
    organization = Partners.organization(organization_id)

    credentials =
      organization.services["bigquery"]
      |> case do
        nil -> %{url: nil, id: nil, email: nil}
        credentials -> credentials
      end

    project_id = credentials.secrets["project_id"]
    dataset_id = credentials.secrets["dataset_id"]
    table_id = table
    token = token(credentials)
    conn = Connection.new(token.token)

    Tabledata.bigquery_tabledata_insert_all(
      conn,
      project_id,
      dataset_id,
      table_id,
      [body: %{rows: data}],
      []
    )

    :ok
  end
end