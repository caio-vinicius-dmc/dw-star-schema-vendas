# Decisões de modelagem

## Grao do fato

Uma linha por **item de pedido**, que é o nível mais detalhado disponível na
origem.

A tentação de agregar por pedido existe: menos linhas, consulta mais rápida.
Mas basta alguém pedir "margem por subcategoria" para o modelo inteiro
precisar ser refeito, porque a informação de produto só existe no item.

Agregar é sempre possível depois; desagregar, não.

## Estrela, e não floco de neve

Categoria e subcategoria ficam dentro de `dim_produto`, como colunas.
Normaliza-las em tabelas próprias economizaria alguns kilobytes e custaria
uma junção a mais em toda consulta analítica.

Em modelo transacional a normalização protege a consistência da escrita. Em
modelo analítico não há escrita concorrente -- o dado vem de uma carga
controlada -- então a redundância é barata e a leitura simples vale mais.

## Chaves substitutas

O fato guarda `sk_cliente`, não `id_cliente`. Três razões:

1. **SCD2 depende disso.** Duas versões do mesmo cliente tem o mesmo
   `id_cliente` e `sk_cliente` diferentes. Sem a chave substituta não há
   como ligar a venda a versão certa.
2. **Independência da origem.** Se o sistema transacional for trocado e os
   ids mudarem, o remapeamento acontece na dimensão. O fato não muda.
3. **Tamanho.** Um inteiro ocupa menos que uma chave natural composta de
   texto, e o fato é a tabela com milhões de linhas.

A exceção é `dim_data`, cuja chave é a data no formato `AAAAMMDD`. Perde-se
pouco e ganha-se legibilidade na hora de depurar -- `20250314` diz
imediatamente de que dia é a linha.

O fato também guarda `id_pedido` e `numero_item`, as chaves naturais. Elas
não são usadas em junção; existem para reconciliar com a origem e para
servirem de chave do upsert na recarga.

## SCD tipo 2 em cliente, tipo 1 nos demais

`dim_cliente` versiona. Segmento e cidade mudam, e a análise precisa saber
o que o cliente era na epoca da venda: se um cliente virou Corporativo em
2026, as compras dele em 2024 continuam contando como Varejo.

`dim_produto` e `dim_loja` sobrescrevem. Quando o nome de um produto e
corrigido, a correção vale para trás também -- ninguém quer ver o nome
errado num relatório do ano passado. O preço de lista também sobrescreve,
porque o preço efetivamente praticado já está congelado no fato
(`valor_bruto` e `valor_liquido` guardam o valor do momento da venda).

### A proteção mais importante

```sql
CREATE UNIQUE INDEX idx_cliente_vigente
    ON dw.dim_cliente (id_cliente) WHERE vigente;
```

Duas versões vigentes do mesmo cliente fariam a junção do fato devolver
duas linhas para cada venda, e a receita apareceria dobrada. O índice
único parcial transforma esse erro em falha na carga, que é infinitamente
melhor do que um relatório errado que ninguém percebe.

A ordem dos passos na carga (`20_carga_dimensoes.sql`) existe por causa
dele: fechar a versão antiga vem antes de abrir a nova. Inverter cria, por
um instante, duas versões vigentes, e o índice rejeita a transação inteira.

## Métricas calculadas na carga, não no relatório

`valor_liquido`, `custo_total` e `margem` são colunas gravadas no fato, e
não formulas na ferramenta de BI.

O motivo é a consistência: se cada relatório calculasse margem por conta
própria, bastaria um deles esquecer de descontar o desconto para dois
dashboards mostrarem números diferentes para a mesma pergunta. Com a
métrica no fato, a regra existe em um lugar só.

O que fica no DAX são as **razões** (margem %, ticket médio) e a
inteligência de tempo, que dependem do contexto de filtro e não poderiam
ser pre-calculadas.

## Filtro de status na carga

Apenas pedidos `faturado` entram no fato. Cancelado e pendente não são
venda.

Essa regra mora no ETL (`21_carga_fato.sql`), não na ferramenta de BI, pelo
mesmo argumento acima: uma regra de negocio espalhada por dez relatórios
vira dez versões diferentes da verdade.

## A conferência, e por que ela existe

`30_conferencia.sql` compara o DW com a origem: contagem de linhas, receita
total, versões vigentes duplicadas, chaves órfãs, dias faltando na
dimensão de data e margem negativa.

Ela não é enfeite. Na primeira execução deste projeto a carga completou sem
nenhum erro e o fato ficou com **225.433 linhas, quando deveria ter
276.727**. Cinquenta e uma mil linhas desapareceram em silêncio.

A causa: a geração da base criava clientes com data de cadastro até 2025,
mas os pedidos comecavam em 2024. Um cliente cadastrado em marco de 2025
com um pedido em maio de 2024 não tinha nenhuma versão valida naquela data,
e o `JOIN` -- que é interno -- simplesmente descartava a linha.

É o modo clássico de falha de um DW: nada quebra, nada avisa, e o número do
relatório fica 18% menor que o do sistema de origem. Sem a conferência,
isso só apareceria numa reuniao.

A correção foi na geração dos dados (cadastro passou a ser sempre anterior
ao período de vendas), mas a licao ficou: **junção interna entre fato e
dimensão versionada é um lugar onde linhas somem**. Em produção vale
considerar `LEFT JOIN` com uma linha "desconhecido" na dimensão, para que a
venda apareca mesmo sem cliente correspondente.

## O que ficou de fora

- **Particionamento do fato.** Com 277 mil linhas não faz diferença. A
  partir de algumas dezenas de milhões, particionar por ano ou mês vale a
  pena.
- **Dimensão "desconhecido".** Conforme o paragrafo acima, seria a próxima
  melhoria mais útil.
- **Tabelas agregadas.** As views `vw_resumo_mensal` e afins calculam na
  hora. Se a consulta ficasse lenta, o caminho seria uma view
  materializada atualizada no fim da carga.
- **Carga incremental.** A carga do fato reprocessa tudo a cada execução.
  E aceitável neste volume, mas um DW de verdade processaria apenas a
  janela alterada.
