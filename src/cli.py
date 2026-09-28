"""Linha de comando do data warehouse.

    python -m src.cli migrar        # cria os schemas origem, dw e bi
    python -m src.cli semear        # popula a base transacional simulada
    python -m src.cli carregar      # roda o ETL origem -> modelo dimensional
    python -m src.cli conferir      # reconcilia o DW com a origem
    python -m src.cli mudar-origem  # simula mudanças para exercitar o SCD2
    python -m src.cli resumo        # mostra as views de consumo
"""

from __future__ import annotations

import argparse
import sys
import time

from rich.console import Console
from rich.table import Table

from . import banco, config

console = Console()


def _frase_versionados(quantidade: int) -> str:
    """Concorda o verbo com o número.

    "1 clientes tem" entrega texto montado por concatenação, e o leitor
    desconfia do resto do relatório junto.
    """
    if quantidade == 1:
        return "1 cliente tem mais de uma versão na dimensão."
    return f"{_br(quantidade)} clientes têm mais de uma versão na dimensão."


def _br(valor, casas: int = 0) -> str:
    """Número no padrão brasileiro: ponto no milhar, virgula no decimal."""
    if valor is None:
        return "-"
    return f"{valor:,.{casas}f}".replace(",", "@").replace(".", ",").replace("@", ".")


def comando_migrar(args: argparse.Namespace) -> int:
    cfg = config.carregar()
    console.print(f"Conectando em {cfg.destino_legivel()}...")
    banco.esperar_banco(cfg)

    for script in banco.executar_scripts(cfg, ["01_origem", "02_modelo", "03_views"]):
        console.print(f"  {script}")

    console.print("Schemas origem, dw e bi criados.")
    return 0


def comando_semear(args: argparse.Namespace) -> int:
    cfg = config.carregar()
    banco.esperar_banco(cfg)

    console.print(
        f"Gerando a base transacional: {_br(cfg.qtd_pedidos)} pedidos, "
        f"{_br(cfg.qtd_clientes)} clientes, {_br(cfg.qtd_produtos)} produtos."
    )
    inicio = time.perf_counter()
    banco.semear_origem(cfg)
    decorrido = time.perf_counter() - inicio

    tabela = Table(title=f"Origem carregada em {_br(decorrido, 1)}s")
    tabela.add_column("Tabela")
    tabela.add_column("Linhas", justify="right")
    for nome, qtd in banco.contar(cfg, "origem").items():
        tabela.add_row(nome, _br(qtd))
    console.print(tabela)

    console.print("Próximo passo: [bold]python -m src.cli carregar[/bold]")
    return 0


def comando_carregar(args: argparse.Namespace) -> int:
    cfg = config.carregar()
    banco.esperar_banco(cfg)

    console.print("Carregando dimensões...")
    inicio = time.perf_counter()
    banco.executar_scripts(cfg, ["20_carga_dimensoes"])
    console.print("Carregando o fato...")
    banco.executar_scripts(cfg, ["21_carga_fato"])
    decorrido = time.perf_counter() - inicio

    tabela = Table(title=f"Carga concluída em {_br(decorrido, 1)}s")
    tabela.add_column("Tabela")
    tabela.add_column("Linhas", justify="right")
    for nome, qtd in banco.contar(cfg, "dw").items():
        tabela.add_row(nome, _br(qtd))
    console.print(tabela)

    versionados = banco.consultar(
        cfg,
        """
        SELECT count(*) AS clientes
          FROM (SELECT id_cliente FROM dw.dim_cliente
                 GROUP BY id_cliente HAVING count(*) > 1) AS t
        """,
    )
    if versionados[0]["clientes"]:
        console.print(
            _frase_versionados(versionados[0]['clientes'])
        )

    return 0


def comando_conferir(args: argparse.Namespace) -> int:
    cfg = config.carregar()
    banco.esperar_banco(cfg)

    linhas = banco.executar_arquivo_com_retorno(cfg, "30_conferencia")

    tabela = Table(title="Conferência do modelo")
    tabela.add_column("Verificação")
    tabela.add_column("Encontrado", justify="right")
    tabela.add_column("Esperado", justify="right")
    tabela.add_column("Situação")

    problemas = 0
    for linha in linhas:
        ok = linha["encontrado"] == linha["esperado"]
        problemas += 0 if ok else 1
        tabela.add_row(
            linha["verificacao"],
            _br(linha["encontrado"], 2),
            _br(linha["esperado"], 2),
            "[green]ok[/green]" if ok else "[red]divergente[/red]",
        )

    console.print(tabela)

    if problemas:
        console.print(f"[red]{problemas} verificações divergentes.[/red]")
        return 1

    console.print("[green]O data warehouse reconcilia com a origem.[/green]")
    return 0


def comando_mudar_origem(args: argparse.Namespace) -> int:
    """Simula o que um sistema transacional faria ao longo do tempo.

    Serve para demonstrar o SCD2: depois de rodar isto e carregar de novo,
    os clientes alterados passam a ter duas versões, e as vendas antigas
    continuam ligadas a versão antiga.
    """
    cfg = config.carregar()
    banco.esperar_banco(cfg)

    alterados = banco.consultar(
        cfg,
        """
        WITH alvo AS (
            SELECT id FROM origem.cliente ORDER BY id LIMIT %s
        )
        UPDATE origem.cliente c
           SET segmento = CASE c.segmento
                              WHEN 'Varejo'      THEN 'Recorrente'
                              WHEN 'Recorrente'  THEN 'Corporativo'
                              WHEN 'Corporativo' THEN 'Atacado'
                              ELSE 'Varejo'
                          END,
               cidade = CASE WHEN c.id %% 2 = 0 THEN 'São Paulo' ELSE c.cidade END,
               uf     = CASE WHEN c.id %% 2 = 0 THEN 'SP' ELSE c.uf END,
               atualizado_em = now()
          FROM alvo
         WHERE c.id = alvo.id
        RETURNING c.id, c.nome, c.segmento, c.cidade
        """,
        (args.clientes,),
    )

    tabela = Table(title=f"{len(alterados)} clientes alterados na origem")
    tabela.add_column("id")
    tabela.add_column("Nome")
    tabela.add_column("Novo segmento")
    tabela.add_column("Cidade")
    for linha in alterados[:10]:
        tabela.add_row(
            str(linha["id"]), linha["nome"], linha["segmento"], linha["cidade"]
        )
    console.print(tabela)

    console.print(
        "Rode [bold]python -m src.cli carregar[/bold] e depois consulte "
        "[bold]bi.vw_historico_cliente[/bold] para ver as duas versões."
    )
    return 0


def comando_resumo(args: argparse.Namespace) -> int:
    cfg = config.carregar()
    banco.esperar_banco(cfg)

    mensal = banco.consultar(
        cfg,
        "SELECT * FROM bi.vw_resumo_mensal ORDER BY ano_mes DESC LIMIT %s",
        (args.meses,),
    )
    tabela = Table(title="Resumo mensal (bi.vw_resumo_mensal)")
    for coluna in ("Mês", "Pedidos", "Itens", "Receita", "Margem %", "Ticket médio"):
        tabela.add_column(coluna, justify="right" if coluna != "Mes" else "left")
    for linha in reversed(mensal):
        tabela.add_row(
            linha["ano_mes"],
            _br(linha["pedidos"]),
            _br(linha["itens"]),
            _br(linha["receita"], 2),
            _br(linha["margem_pct"], 1),
            _br(linha["ticket_medio"], 2),
        )
    console.print(tabela)

    categorias = banco.consultar(
        cfg,
        "SELECT * FROM bi.vw_margem_categoria ORDER BY receita DESC LIMIT 8",
    )
    tabela = Table(title="Margem por categoria (bi.vw_margem_categoria)")
    for coluna in ("Categoria", "Subcategoria", "Receita", "Margem", "Margem %"):
        tabela.add_column(coluna)
    for linha in categorias:
        tabela.add_row(
            linha["categoria"],
            linha["subcategoria"],
            _br(linha["receita"], 2),
            _br(linha["margem"], 2),
            _br(linha["margem_pct"], 1),
        )
    console.print(tabela)
    return 0


def construir_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dw-vendas",
        description="Data warehouse dimensional de vendas em PostgreSQL.",
    )
    sub = parser.add_subparsers(dest="comando", required=True)

    for nome, ajuda, funcao in (
        ("migrar", "cria os schemas e tabelas", comando_migrar),
        ("semear", "popula a base transacional simulada", comando_semear),
        ("carregar", "roda o ETL para o modelo dimensional", comando_carregar),
        ("conferir", "reconcilia o DW com a origem", comando_conferir),
    ):
        p = sub.add_parser(nome, help=ajuda)
        p.set_defaults(funcao=funcao)

    p_mudar = sub.add_parser(
        "mudar-origem", help="altera clientes na origem para exercitar o SCD2"
    )
    p_mudar.add_argument("--clientes", type=int, default=50)
    p_mudar.set_defaults(funcao=comando_mudar_origem)

    p_resumo = sub.add_parser("resumo", help="mostra as views de consumo")
    p_resumo.add_argument("--meses", type=int, default=8)
    p_resumo.set_defaults(funcao=comando_resumo)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = construir_parser().parse_args(argv)
    try:
        return args.funcao(args)
    except (RuntimeError, FileNotFoundError) as erro:
        console.print(f"[red]{erro}[/red]")
        return 2


if __name__ == "__main__":
    sys.exit(main())
