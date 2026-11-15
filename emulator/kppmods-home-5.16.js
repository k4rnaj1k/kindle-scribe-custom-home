// Preserve stock Home lifecycle and navigation; replace only its content renderer.
//
// Local variant of kppmods ui/adapters/home.js (commit 172e9a9) that also
// supports 5.16.x firmware. Newer firmware exposes a prototype method
// `renderHomeFeed`; on 5.16.6.1 HomeView.prototype.render returns a parent View
// holding the stock pager (which renders the per-instance `_renderHomeCards`),
// so the pager child is replaced instead.
module.exports = function installHome(host) {
  const {
    loadStockModule,
    patchStockMethod,
    useRegistry,
    React,
    ReactNative,
    ExtensionErrorBoundary
  } = host;
  const home = loadStockModule(
    'views',
    (moduleExports) => moduleExports.KPPViews && moduleExports.KPPViews.KPP_HOME
  ).KPPViews.KPP_HOME;
  const prototype = home.component && home.component.prototype;
  function CustomHome({ renderStock, homeProps }) {
    const items = useRegistry('home');
    if (!items.length) return renderStock();
    return React.createElement(
      ReactNative.View,
      {
        style: {
          flex: 1
        }
      },
      items.map((item) =>
        React.createElement(
          ExtensionErrorBoundary,
          {
            key: item.id + ':' + item.revision,
            owner: item.owner
          },
          React.createElement(item.component, homeProps)
        )
      )
    );
  }
  if (prototype && typeof prototype.renderHomeFeed === 'function') {
    patchStockMethod(
      'home',
      prototype,
      'renderHomeFeed',
      (original) =>
        function (...args) {
          return React.createElement(CustomHome, {
            renderStock: () => original.apply(this, args),
            homeProps: this.props
          });
        }
    );
    return;
  }
  if (!prototype || typeof prototype.render !== 'function')
    throw new Error('Stock Home route has no content renderer');
  // 5.16 render() returns View(HomeParentView_*) > stock pager > cards. The
  // pager sizes its scrollbar from the stock card list, so replace the whole
  // pager (not just the cards) when a custom Home is registered; with none,
  // CustomHome hands back the untouched stock pager.
  patchStockMethod(
    'home',
    prototype,
    'render',
    (original) =>
      function (...args) {
        const tree = original.apply(this, args);
        if (!tree || !tree.props) return tree;
        const stockPager = tree.props.children;
        return React.cloneElement(
          tree,
          undefined,
          React.createElement(CustomHome, {
            renderStock: () => stockPager,
            homeProps: this.props
          })
        );
      }
  );
};
