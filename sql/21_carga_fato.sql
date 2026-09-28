-- Carga do fato.
--
-- Apenas pedidos faturados entram: cancelado e pendente não são venda. Essa
-- e uma regra de negocio, e ela mora aqui -- não na ferramenta de BI. Se
-- cada relatório tivesse que lembrar de filtrar o status, mais cedo ou
-- mais tarde um deles esqueceria e os números não bateriam entre si.

INSERT INTO dw.fato_venda (
    sk_data, sk_cliente, sk_produto, sk_loja,
    id_pedido, numero_item,
    quantidade, valor_bruto, desconto, valor_liquido, custo_total, margem
)
SELECT
    dd.sk_data,
    dc.sk_cliente,
    dp.sk_produto,
    dl.sk_loja,
    p.id,
    i.numero_item,
    i.quantidade,
    round(i.preco_unitario * i.quantidade, 2)                        AS valor_bruto,
    round(i.desconto * i.quantidade, 2)                              AS desconto,
    round((i.preco_unitario - i.desconto) * i.quantidade, 2)         AS valor_liquido,
    round(dp.custo * i.quantidade, 2)                                AS custo_total,
    round(((i.preco_unitario - i.desconto) - dp.custo) * i.quantidade, 2) AS margem
FROM origem.item_pedido i
JOIN origem.pedido  p  ON p.id = i.pedido_id
JOIN dw.dim_data    dd ON dd.data = (p.criado_em AT TIME ZONE 'America/Sao_Paulo')::date
-- A junção com dim_cliente usa a versão vigente na data da venda. E o que
-- faz o SCD2 valer a pena: uma venda de 2024 fica presa ao segmento que o
-- cliente tinha em 2024, mesmo que ele tenha mudado depois.
JOIN dw.dim_cliente dc ON dc.id_cliente = p.cliente_id
                      AND (p.criado_em AT TIME ZONE 'America/Sao_Paulo')::date
                          BETWEEN dc.valido_de AND dc.valido_ate
JOIN dw.dim_produto dp ON dp.id_produto = i.produto_id
JOIN dw.dim_loja    dl ON dl.id_loja    = p.loja_id
WHERE p.status = 'faturado'
-- Reprocessar a carga atualiza as linhas existentes em vez de duplicar.
-- A chave do conflito e a natural (pedido + item), não a substituta.
ON CONFLICT (id_pedido, numero_item) DO UPDATE
    SET sk_data       = EXCLUDED.sk_data,
        sk_cliente    = EXCLUDED.sk_cliente,
        sk_produto    = EXCLUDED.sk_produto,
        sk_loja       = EXCLUDED.sk_loja,
        quantidade    = EXCLUDED.quantidade,
        valor_bruto   = EXCLUDED.valor_bruto,
        desconto      = EXCLUDED.desconto,
        valor_liquido = EXCLUDED.valor_liquido,
        custo_total   = EXCLUDED.custo_total,
        margem        = EXCLUDED.margem;

ANALYZE dw.fato_venda;
