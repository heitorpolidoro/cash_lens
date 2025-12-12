defmodule CashLens.DateUtils do
  # A lista começa com a Segunda-feira (índice 0)
  @day_names [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday"
  ]

  def day_name(date_or_datetime) do
    # 1. Pega o número do dia (ex: 3 para Quarta-feira)
    day_number = Date.day_of_week(date_or_datetime)

    # 2. Usa o número para pegar o nome no índice correto.
    # Como a lista é baseada em 0 e o day_number é baseada em 1, subtraímos 1.
    Enum.at(@day_names, day_number - 1)
  end
end
