"""Conexão e execução dos scripts SQL.

Quase toda a lógica do projeto está em SQL, não em Python. E uma escolha:
transformação de dados dentro do banco evita trafegar milhões de linhas
pela rede só para devolve-las alteradas, e deixa o código legível para
quem trabalha com DW mas não programa em Python.

O Python aqui faz o papel de orquestrador -- conecta, executa na ordem
certa e formata o resultado.
"""

from __future__ import annotations

import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

import psycopg
from psycopg.rows import dict_row

from .config import RAIZ, Config

PASTA_SQL = RAIZ / "sql"


@contextmanager
def conectar(cfg: Config) -> Iterator[psycopg.Connection]:
    with psycopg.connect(cfg.dsn, row_factory=dict_row) as conn:
        yield conn


def esperar_banco(cfg: Config, tentativas: int = 30, intervalo: float = 2.0) -> None:
    ultimo_erro: Exception | None = None
    for _ in range(tentativas):
        try:
            with psycopg.connect(cfg.dsn, connect_timeout=3) as conn:
                conn.execute("SELECT 1")
            return
        except psycopg.OperationalError as erro:
            # Senha recusada não melhora com nova tentativa -- insistir só
            # faz o comando demorar um minuto para dar a mensagem errada.
            #
            # O caso clássico e o volume do Docker ter sido criado com outra
            # senha: o Postgres só lê POSTGRES_PASSWORD na primeira
            # inicialização do diretório de dados e ignora a mudança no .env
            # depois disso.
            if "password authentication failed" in str(erro):
                raise RuntimeError(
                    f"O banco recusou a senha de {cfg.destino_legivel()}. "
                    "Se você mudou POSTGRES_PASSWORD depois de já ter subido o "
                    "container, o volume antigo ainda guarda a senha original. "
                    "Recrie o ambiente com: docker compose down -v && docker compose up -d"
                ) from erro

            ultimo_erro = erro
            time.sleep(intervalo)
    raise RuntimeError(
        f"Sem conexão com {cfg.destino_legivel()}. "
        f"O container subiu? Último erro: {ultimo_erro}"
    )


def _ler_script(nome: str) -> str:
    caminho = PASTA_SQL / f"{nome}.sql"
    if not caminho.exists():
        raise FileNotFoundError(f"Script não encontrado: {caminho}")
    return caminho.read_text(encoding="utf-8")


def executar_scripts(cfg: Config, nomes: list[str]) -> list[str]:
    """Executa os scripts na ordem informada, cada um em sua transação.

    Transações separadas por script são intencionais: se a carga do fato
    falhar, as dimensões já carregadas permanecem e a próxima tentativa
    não precisa refazer tudo.
    """
    executados = []
    for nome in nomes:
        with conectar(cfg) as conn:
            conn.execute(_ler_script(nome))
        executados.append(f"{nome}.sql")
    return executados


def executar_arquivo_com_retorno(cfg: Config, nome: str) -> list[dict]:
    with conectar(cfg) as conn:
        return conn.execute(_ler_script(nome)).fetchall()


def semear_origem(cfg: Config) -> None:
    sql = _ler_script("10_semear_origem").format(
        qtd_clientes=int(cfg.qtd_clientes),
        qtd_produtos=int(cfg.qtd_produtos),
        qtd_pedidos=int(cfg.qtd_pedidos),
    )
    with conectar(cfg) as conn:
        conn.execute(sql)


def consultar(cfg: Config, sql: str, parametros: tuple = ()) -> list[dict]:
    with conectar(cfg) as conn:
        return conn.execute(sql, parametros).fetchall()


def contar(cfg: Config, schema: str) -> dict[str, int]:
    """Conta as linhas de todas as tabelas do schema, em ordem de nome."""
    with conectar(cfg) as conn:
        tabelas = [
            linha["tablename"]
            for linha in conn.execute(
                "SELECT tablename FROM pg_tables WHERE schemaname = %s ORDER BY tablename",
                (schema,),
            ).fetchall()
        ]
        return {
            tabela: conn.execute(
                f"SELECT count(*) AS total FROM {schema}.{tabela}"
            ).fetchone()["total"]
            for tabela in tabelas
        }
