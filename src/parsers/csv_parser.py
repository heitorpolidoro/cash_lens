import csv
import re
from datetime import datetime, timedelta

from dateutil.parser import parse

from models import Transaction, Category
from p_question import Question
from utils.string import currency


def validate_transaction(transaction):
    while True:
        if Question("Is correct", type=bool, default=True).ask():
            transaction.save()
            break
        else:
            options ={
                    f"{c.key}: {transaction[c.key]}": c
                    for c in transaction.columns()
                    if c.key != "id"
                }
            column = Question(
                "What do you want to change",
                options=options,
                auto_complete=True,
            ).ask()
            setattr(
                transaction,
                column.key,
                transaction.ask_column_value(column),
            )


def parse_bb_cc(file_name, account, skip_confirmation=False):
    print(f"[CSV] Parsing '{file_name}'")
    historico_to_ignore = ["Saldo Anterior", "BB Rende Fácil - Rende Facil", "BB Rende Fácil", "S A L D O"]
    with open(file_name, encoding="latin-1") as csv_file:
        csv_reader = csv.DictReader(csv_file, delimiter=",")

        for row in csv_reader:
            if row["Histórico"] in historico_to_ignore:
                print(f"Ignoring '{row['Histórico']}'")
                continue

            # print(row)

            date = parse(row["Data"], dayfirst=True)
            reason = row["Histórico"]
            reason = reason.replace("Compra com Cartão - ", "").strip()
            value = row["Valor"]
            if real_date := re.search(r"[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}", reason):
                real_date = datetime.strptime(real_date.group(), "%d/%m %H:%M")
                reason = reason.replace(real_date.strftime("%d/%m %H:%M"), "").strip()
                date = real_date.replace(year=date.year)

            category = None
            if (
                categories := Transaction.filter(
                    reason_ilike=reason, date_gte=datetime.now() - timedelta(days=365)
                )
                .join(Transaction.category)
                .with_entities(Category)
                .group_by(Transaction.category)
                .all()
            ):
                if len(categories) == 1:
                    category = categories[0]
            else:
                category = Category.ask(create=True,
                    message=f"{date.strftime('%d/%m/%Y %H:%M (%A)')} {reason} {currency(value, False)}"
                )

            date = date.date()
            transaction = Transaction.create(
                account=account,
                quiet=True,
                date=date,
                value=value,
                reason=reason,
                category=category,
                # installment=recurrent_reason,
                ask_only_not_null=True,
                save=False,
            )
            print(transaction)
            if same_transaction := Transaction.filter(
                account=account,
                date=date,
                value=value,
                reason_ilike=reason,
                #category=category,
            ).first():
                print(same_transaction)
                if skip_confirmation:
                    print("Skipping")
                    continue
                if not Question(
                    "There is another transaction with the same info. Is this another transaction?",
                    type=bool,
                    default=False,
                ).ask():
                    continue
            validate_transaction(transaction)
