-- Conferência do modelo. Cada consulta devolve uma linha com o nome do
-- teste, o valor encontrado e o valor esperado.
--
-- Rodar isso depois de toda carga é o que evita a conversa mais
-- desagradável do trabalho com BI: descobrir pelo usuário que o número do
-- relatório não bate com o do sistema de origem.

WITH
-- 1. Todo item faturado da origem virou linha no fato?
volume AS (
    SELECT
        'linhas do fato x itens faturados na origem' AS verificacao,
        (SELECT count(*) FROM dw.fato_venda)::numeric AS encontrado,
        (SELECT count(*)
           FROM origem.item_pedido i
           JOIN origem.pedido p ON p.id = i.pedido_id
          WHERE p.status = 'faturado')::numeric        AS esperado
),
-- 2. A receita total bate com a origem?
receita AS (
    SELECT
        'receita líquida total',
        (SELECT round(sum(valor_liquido), 2) FROM dw.fato_venda),
        (SELECT round(sum((i.preco_unitario - i.desconto) * i.quantidade), 2)
           FROM origem.item_pedido i
           JOIN origem.pedido p ON p.id = i.pedido_id
          WHERE p.status = 'faturado')
),
-- 3. O índice único parcial já impede duas versões vigentes, mas a
--    conferência fica aqui para o caso de alguém remove-lo no futuro.
versoes AS (
    SELECT
        'clientes com mais de uma versão vigente',
        (SELECT count(*) FROM (
            SELECT id_cliente FROM dw.dim_cliente
             WHERE vigente GROUP BY id_cliente HAVING count(*) > 1
        ) AS t)::numeric,
        0::numeric
),
-- 4. Chave substituta órfã no fato. As FKs cobrem isso, mas em DW é comum
--    elas serem removidas por desempenho -- dai a conferência explícita.
orfas AS (
    SELECT
        'linhas do fato sem dimensão correspondente',
        (SELECT count(*)
           FROM dw.fato_venda f
          WHERE NOT EXISTS (SELECT 1 FROM dw.dim_data    d WHERE d.sk_data    = f.sk_data)
             OR NOT EXISTS (SELECT 1 FROM dw.dim_cliente c WHERE c.sk_cliente = f.sk_cliente)
             OR NOT EXISTS (SELECT 1 FROM dw.dim_produto p WHERE p.sk_produto = f.sk_produto)
             OR NOT EXISTS (SELECT 1 FROM dw.dim_loja    l WHERE l.sk_loja    = f.sk_loja)
        )::numeric,
        0::numeric
),
-- 5. Buraco na dimensão de data: dia com venda que não existe em dim_data.
--    Se isso acontecer, a carga do fato teria perdido linhas na junção.
cobertura_data AS (
    SELECT
        'dias com venda ausentes na dim_data',
        (SELECT count(DISTINCT (p.criado_em AT TIME ZONE 'America/Sao_Paulo')::date)
           FROM origem.pedido p
          WHERE p.status = 'faturado'
            AND NOT EXISTS (
                SELECT 1 FROM dw.dim_data d
                 WHERE d.data = (p.criado_em AT TIME ZONE 'America/Sao_Paulo')::date
            ))::numeric,
        0::numeric
),
-- 6. Margem negativa em volume alto costuma indicar custo mal carregado.
margem AS (
    SELECT
        'itens com margem negativa',
        (SELECT count(*) FROM dw.fato_venda WHERE margem < 0)::numeric,
        0::numeric
)
SELECT * FROM volume
UNION ALL SELECT * FROM receita
UNION ALL SELECT * FROM versoes
UNION ALL SELECT * FROM orfas
UNION ALL SELECT * FROM cobertura_data
UNION ALL SELECT * FROM margem;
