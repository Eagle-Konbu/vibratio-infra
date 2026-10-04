import { util } from '@aws-appsync/utils';

export function request() {
  return {
    operation: 'Query',
    query: {
      expression: 'pk = :pk',
      expressionValues: util.dynamodb.toMapValues({ ':pk': 'SOURCE' }),
    },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result.items.map((item) => ({ ...item, id: item.sk }));
}
